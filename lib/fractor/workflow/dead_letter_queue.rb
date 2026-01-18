# frozen_string_literal: true

module Fractor
  class Workflow
    # Dead Letter Queue for capturing permanently failed work
    #
    # The dead letter queue captures work items that have exhausted all
    # retry attempts and cannot be processed successfully. This provides
    # a mechanism for:
    #
    # - Preventing data loss for failed items
    # - Enabling manual inspection and reprocessing
    # - Supporting different persistence strategies
    # - Providing visibility into failure patterns
    #
    # @example Basic usage
    #   dlq = DeadLetterQueue.new(max_size: 1000)
    #   dlq.add(work, error, context)
    #   failed_items = dlq.all
    #
    # @example With handler
    #   dlq = DeadLetterQueue.new
    #   dlq.on_add do |entry|
    #     Logger.error("Dead letter: #{entry.error}")
    #   end
    class DeadLetterQueue
      # Entry in the dead letter queue
      class Entry
        attr_reader :work, :error, :context, :timestamp, :metadata

        def initialize(work:, error:, context: nil, metadata: {})
          @work = work
          @error = error
          @context = context
          @timestamp = Time.now
          @metadata = metadata
        end

        # Convert entry to hash for serialization
        #
        # @return [Hash] Entry data as hash
        def to_h
          {
            work: work,
            error: error.to_s,
            error_class: error.class.name,
            context: context&.to_h,
            timestamp: timestamp.iso8601,
            metadata: metadata,
          }
        end
      end

      attr_reader :max_size, :entries

      # Initialize a new dead letter queue
      #
      # @param max_size [Integer] Maximum queue size (nil for unlimited)
      # @param persistence [Symbol] Persistence strategy (:memory, :file, :redis, :database)
      # @param persistence_options [Hash] Options for persistence backend
      def initialize(max_size: nil, persistence: :memory, **persistence_options)
        @max_size = max_size
        @entries = []
        @handlers = []
        @mutex = Mutex.new
        @persistence = persistence
        @persistence_options = persistence_options
        @persister = create_persister(persistence, persistence_options)
      end

      # Add a failed work item to the dead letter queue
      #
      # @param work [Fractor::Work] The failed work item
      # @param error [Exception] The error that caused failure
      # @param context [Hash] Additional context about the failure
      # @param metadata [Hash] Additional metadata
      # @return [Entry] The created entry
      def add(work, error, context: nil, metadata: {})
        entry = Entry.new(
          work: work,
          error: error,
          context: context,
          metadata: metadata,
        )

        @mutex.synchronize do
          # Enforce max size if set
          if max_size && @entries.size >= max_size
            # Remove oldest entry
            removed = @entries.shift
            @persister&.remove(removed)
          end

          @entries << entry
          @persister&.persist(entry)
        end

        # Notify handlers
        notify_handlers(entry)

        entry
      end

      # Enqueue a failed work item to the dead letter queue (alias for add)
      # Standardized API method name for consistency across queue implementations
      #
      # @param work [Fractor::Work] The failed work item
      # @param error [Exception] The error that caused failure
      # @param context [Hash] Additional context about the failure
      # @param metadata [Hash] Additional metadata
      # @return [Entry] The created entry
      def enqueue(work, error, context: nil, metadata: {})
        add(work, error, context: context, metadata: metadata)
      end

      # Register a handler to be called when items are added
      #
      # @yield [Entry] Block to execute when item is added
      def on_add(&block)
        @handlers << block if block
      end

      # Get all entries in the queue
      #
      # @return [Array<Entry>] All entries
      def all
        @mutex.synchronize { @entries.dup }
      end

      # Get entries matching a filter
      #
      # @yield [Entry] Block to filter entries
      # @return [Array<Entry>] Filtered entries
      def filter(&block)
        @mutex.synchronize { @entries.select(&block) }
      end

      # Get entries for a specific error class
      #
      # @param error_class [Class] Error class to filter by
      # @return [Array<Entry>] Matching entries
      def by_error_class(error_class)
        filter { |entry| entry.error.is_a?(error_class) }
      end

      # Get entries within a time range
      #
      # @param start_time [Time] Start of time range
      # @param end_time [Time] End of time range (defaults to now)
      # @return [Array<Entry>] Entries in time range
      def by_time_range(start_time, end_time = Time.now)
        filter do |entry|
          entry.timestamp >= start_time && entry.timestamp <= end_time
        end
      end

      # Remove an entry from the queue
      #
      # @param entry [Entry] Entry to remove
      # @return [Entry, nil] Removed entry or nil
      def remove(entry)
        @mutex.synchronize do
          if @entries.delete(entry)
            @persister&.remove(entry)
            entry
          end
        end
      end

      # Clear all entries from the queue
      #
      # @return [Integer] Number of entries cleared
      def clear
        @mutex.synchronize do
          count = @entries.size
          @entries.clear
          @persister&.clear
          count
        end
      end

      # Get the current size of the queue
      #
      # @return [Integer] Number of entries
      def size
        @mutex.synchronize { @entries.size }
      end

      # Check if queue is empty
      #
      # @return [Boolean] True if empty
      def empty?
        size.zero?
      end

      # Check if queue is at capacity
      #
      # @return [Boolean] True if at max_size
      def full?
        return false unless max_size

        size >= max_size
      end

      # Get statistics about the queue
      #
      # @return [Hash] Queue statistics
      def stats
        entries_copy = all

        {
          size: entries_copy.size,
          max_size: max_size,
          full: full?,
          oldest_timestamp: entries_copy.first&.timestamp,
          newest_timestamp: entries_copy.last&.timestamp,
          error_classes: entries_copy.map { |e| e.error.class.name }.uniq,
          persistence: @persistence,
        }
      end

      # Retry a specific entry
      #
      # @param entry [Entry] Entry to retry
      # @yield [Work] Block to process the work
      # @return [Boolean] True if retry succeeded
      def retry_entry(entry, &block)
        return false unless block

        begin
          yield(entry.work)
          remove(entry)
          true
        rescue StandardError => e
          # Add back to queue with new error
          remove(entry)
          add(entry.work, e, context: entry.context,
                             metadata: entry.metadata.merge(retried: true))
          false
        end
      end

      # Retry all entries
      #
      # @yield [Work] Block to process each work item
      # @return [Hash] Results with :success and :failed counts
      def retry_all(&block)
        return { success: 0, failed: 0 } unless block

        results = { success: 0, failed: 0 }
        entries_to_retry = all

        entries_to_retry.each do |entry|
          if retry_entry(entry, &block)
            results[:success] += 1
          else
            results[:failed] += 1
          end
        end

        results
      end

      private

      def notify_handlers(entry)
        @handlers.each do |handler|
          handler.call(entry)
        rescue StandardError => e
          warn "Dead letter queue handler error: #{e.message}"
        end
      end

      def create_persister(persistence, options)
        case persistence
        when :memory
          nil # No persistence needed
        when :file
          FilePersister.new(**options)
        when :redis
          RedisPersister.new(**options) if defined?(Redis)
        when :database
          DatabasePersister.new(**options)
        else
          raise ArgumentError, "Unknown persistence strategy: #{persistence}"
        end
      end
    end

    # File-based persistence for dead letter queue
    class FilePersister
      def initialize(file_path: "dead_letter_queue.json")
        @file_path = file_path
        @mutex = Mutex.new
      end

      def persist(entry)
        @mutex.synchronize do
          entries = load_entries
          entries << entry.to_h
          save_entries(entries)
        end
      end

      def remove(entry)
        @mutex.synchronize do
          entries = load_entries
          entries.reject! { |e| e[:timestamp] == entry.timestamp.iso8601 }
          save_entries(entries)
        end
      end

      def clear
        @mutex.synchronize do
          File.delete(@file_path) if File.exist?(@file_path)
        end
      end

      private

      def load_entries
        return [] unless File.exist?(@file_path)

        JSON.parse(File.read(@file_path), symbolize_names: true)
      rescue JSON::ParserError
        []
      end

      def save_entries(entries)
        File.write(@file_path, JSON.pretty_generate(entries))
      end
    end
  end
end
