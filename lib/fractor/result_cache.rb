# frozen_string_literal: true

require "digest"
require "json"

module Fractor
  # Caches work results to avoid redundant processing of identical work items.
  # Useful for expensive, deterministic operations.
  #
  # @example Basic usage
  #   cache = Fractor::ResultCache.new
  #   cached = cache.get(work) { work.process }
  #
  # @example With TTL
  #   cache = Fractor::ResultCache.new(ttl: 300)  # 5 minutes
  class ResultCache
    attr_reader :hits, :misses

    # Initialize a new result cache.
    #
    # @param ttl [Integer, nil] Time-to-live for cache entries in seconds (nil = no expiration)
    # @param max_size [Integer, nil] Maximum number of entries (nil = unlimited)
    # @param max_memory [Integer, nil] Maximum memory usage in bytes (nil = unlimited)
    def initialize(ttl: nil, max_size: nil, max_memory: nil)
      @cache = {}
      @timestamps = {}
      @access_times = {}
      @ttl = ttl
      @max_size = max_size
      @max_memory = max_memory
      @current_memory = 0
      @mutex = Mutex.new
      @hits = 0
      @misses = 0
    end

    # Get the current cache size.
    #
    # @return [Integer] Number of entries in the cache
    def size
      @mutex.synchronize { @cache.size }
    end

    # Get a cached result or compute and cache it.
    #
    # @param work [Fractor::Work] The work item to process
    # @yield Block to compute the result if not cached
    # @return [WorkResult, Object] The cached or computed result
    def get(work)
      key = generate_key(work)

      @mutex.synchronize do
        # Check if we have a valid cached result
        if @cache.key?(key) && !expired?(key)
          @hits += 1
          @access_times[key] = Time.now
          return @cache[key]
        end

        @misses += 1

        # Compute the result
        result = yield

        # Cache the result
        cache_entry(key, result)

        result
      end
    end

    # Check if a work item has a cached result.
    #
    # @param work [Fractor::Work] The work item to check
    # @return [Boolean] true if a valid cached result exists
    def has?(work)
      key = generate_key(work)

      @mutex.synchronize do
        @cache.key?(key) && !expired?(key)
      end
    end

    # Store a result in the cache.
    #
    # @param work [Fractor::Work] The work item
    # @param result [WorkResult, Object] The result to cache
    # @return [void]
    def set(work, result)
      key = generate_key(work)

      @mutex.synchronize do
        cache_entry(key, result)
      end
    end

    # Invalidate a cached result.
    #
    # @param work [Fractor::Work] The work item to invalidate
    # @return [Boolean] true if a cached result was removed
    def invalidate(work)
      key = generate_key(work)

      @mutex.synchronize do
        if @cache.key?(key)
          remove_entry(key)
          true
        else
          false
        end
      end
    end

    # Clear all cached results.
    #
    # @return [void]
    def clear
      @mutex.synchronize do
        @cache.clear
        @timestamps.clear
        @access_times.clear
        @current_memory = 0
      end
    end

    # Get cache statistics.
    #
    # @return [Hash] Cache statistics
    def stats
      @mutex.synchronize do
        total = @hits + @misses
        hit_rate = total.positive? ? (@hits.to_f / total * 100).round(2) : 0

        {
          size: @cache.size,
          hits: @hits,
          misses: @misses,
          hit_rate: hit_rate,
          current_memory: @current_memory,
        }
      end
    end

    # Remove expired entries from the cache.
    #
    # @return [Integer] Number of entries removed
    def cleanup_expired
      @mutex.synchronize do
        expired_keys = @cache.keys.select { |key| expired?(key) }
        expired_keys.each { |key| remove_entry(key) }
        expired_keys.size
      end
    end

    private

    # Generate a cache key for a work item.
    #
    # Optimized to avoid JSON.dump for common simple types.
    # For complex nested structures, falls back to JSON serialization.
    #
    # @param work [Fractor::Work] The work item
    # @return [String] The cache key
    def generate_key(work)
      # For simple types, use faster string interpolation
      # For complex nested structures, fall back to JSON
      input = work.input
      input_str = if simple_input?(input)
                    serialize_simple_input(input)
                  else
                    JSON.dump(input)
                  end

      # Build key components
      parts = [work.class.name, input_str]
      parts << work.timeout.to_s if work.respond_to?(:timeout) && !work.timeout.nil?

      # Use SHA256 hash for consistent, collision-resistant keys
      Digest::SHA256.hexdigest(parts.join("|"))
    end

    # Check if input is a simple type that can be serialized without JSON.
    # @return [Boolean] true if input is a simple, directly serializable type
    def simple_input?(input)
      case input
      when NilClass, TrueClass, FalseClass, String, Numeric, Symbol
        true
      when Array
        input.all? { |item| simple_input?(item) }
      when Hash
        input.keys.all? { |k| k.is_a?(String) || k.is_a?(Symbol) } &&
          input.values.all? { |v| simple_input?(v) }
      else
        false
      end
    end

    # Serialize simple input types efficiently without JSON.
    # @return [String] Serialized representation
    def serialize_simple_input(input)
      case input
      when NilClass
        "nil"
      when TrueClass
        "true"
      when FalseClass
        "false"
      when String
        # Escape special characters for consistent hashing
        input.inspect
      when Symbol
        ":#{input}"
      when Array
        "[#{input.map { |item| serialize_simple_input(item) }.join(',')}]"
      when Hash
        pairs = input.map { |k, v| "#{k}=>#{serialize_simple_input(v)}" }
        "{#{pairs.sort.join(',')}}"
      else
        # Fallback - shouldn't happen if simple_input? is correct
        input.to_s
      end
    end

    # Check if a cache entry is expired.
    #
    # @param key [String] The cache key
    # @return [Boolean] true if the entry is expired
    def expired?(key)
      return false unless @ttl

      timestamp = @timestamps[key]
      return true unless timestamp

      Time.now - timestamp > @ttl
    end

    # Cache a result entry.
    #
    # @param key [String] The cache key
    # @param result [Object] The result to cache
    # @return [void]
    def cache_entry(key, result)
      # Evict oldest entry if max_size reached
      evict_lru if @max_size && @cache.size >= @max_size

      # Estimate memory usage
      estimated_size = estimate_size(result)

      # Evict entries if max_memory reached
      evict_by_memory(estimated_size) if @max_memory

      @cache[key] = result
      @timestamps[key] = Time.now
      @access_times[key] = Time.now
      @current_memory += estimated_size
    end

    # Remove an entry from the cache.
    #
    # @param key [String] The cache key
    # @return [void]
    def remove_entry(key)
      result = @cache.delete(key)
      @timestamps.delete(key)
      @access_times.delete(key)

      if result
        @current_memory -= estimate_size(result)
        @current_memory = 0 if @current_memory.negative?
      end
    end

    # Evict the least-recently-used entry.
    #
    # @return [void]
    def evict_lru
      return if @cache.empty?

      # Find the entry with the oldest access time
      lru_key = @access_times.min_by { |_, time| time }&.first
      remove_entry(lru_key) if lru_key
    end

    # Evict entries to free memory.
    #
    # @param required_size [Integer] The size needed
    # @return [void]
    def evict_by_memory(required_size)
      return unless @max_memory

      while @current_memory + required_size > @max_memory && @cache.any?
        evict_lru
      end
    end

    # Estimate the memory size of an object.
    #
    # @param obj [Object] The object to measure
    # @return [Integer] Estimated size in bytes
    def estimate_size(obj)
      # Rough estimation based on object inspection
      case obj
      when String
        obj.bytesize
      when Hash
        obj.sum { |k, v| estimate_size(k.to_s) + estimate_size(v) }
      when Array
        obj.sum { |v| estimate_size(v) }
      when Fractor::WorkResult
        # Base size + result + error
        size = 100 # Base object overhead
        size += estimate_size(obj.result) if obj.result
        size += estimate_size(obj.error) if obj.error
        size
      else
        100 # Default estimate for unknown objects
      end
    rescue StandardError
      100 # Fallback estimate
    end
  end
end
