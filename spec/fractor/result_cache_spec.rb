# frozen_string_literal: true

require "spec_helper"

RSpec.describe Fractor::ResultCache do
  # Test work class
  class CachedWork < Fractor::Work
    def initialize(value)
      super({ value: value })
    end

    def value
      input[:value]
    end
  end

  describe "#initialize" do
    it "creates a cache with default settings" do
      cache = described_class.new
      expect(cache.size).to eq(0)
      expect(cache.instance_variable_get(:@ttl)).to be_nil
      expect(cache.instance_variable_get(:@max_size)).to be_nil
    end

    it "creates a cache with TTL" do
      cache = described_class.new(ttl: 60)
      expect(cache.instance_variable_get(:@ttl)).to eq(60)
    end

    it "creates a cache with max size" do
      cache = described_class.new(max_size: 100)
      expect(cache.instance_variable_get(:@max_size)).to eq(100)
    end

    it "creates a cache with max memory" do
      cache = described_class.new(max_memory: 1024)
      expect(cache.instance_variable_get(:@max_memory)).to eq(1024)
    end
  end

  describe "#get" do
    it "returns cached result on cache hit" do
      cache = described_class.new
      work = CachedWork.new(42)
      result = Fractor::WorkResult.new(result: 84, work: work)

      cache.set(work, result)
      cached_result = cache.get(work) { raise "Should not be called" }

      expect(cached_result).to eq(result)
      expect(cache.hits).to eq(1)
      expect(cache.misses).to eq(0)
    end

    it "computes and caches result on cache miss" do
      cache = described_class.new
      work = CachedWork.new(42)
      computed_result = Fractor::WorkResult.new(result: 84, work: work)

      result = cache.get(work) { computed_result }

      expect(result).to eq(computed_result)
      expect(cache.hits).to eq(0)
      expect(cache.misses).to eq(1)

      # Second call should hit cache
      cache.get(work) { raise "Should not be called" }
      expect(cache.hits).to eq(1)
    end

    it "generates consistent cache keys for identical work" do
      cache = described_class.new
      work1 = CachedWork.new(42)
      work2 = CachedWork.new(42)
      result = Fractor::WorkResult.new(result: 84, work: work1)

      cache.set(work1, result)
      cached_result = cache.get(work2) { raise "Should not be called" }

      expect(cached_result).to eq(result)
    end

    it "generates different cache keys for different work" do
      cache = described_class.new
      work1 = CachedWork.new(42)
      work2 = CachedWork.new(43)
      result1 = Fractor::WorkResult.new(result: 84, work: work1)
      result2 = Fractor::WorkResult.new(result: 86, work: work2)

      cache.set(work1, result1)
      cache.set(work2, result2)

      expect(cache.get(work1) { result1 }).to eq(result1)
      expect(cache.get(work2) { result2 }).to eq(result2)
    end
  end

  describe "#has?" do
    it "returns true when work is cached" do
      cache = described_class.new
      work = CachedWork.new(42)
      result = Fractor::WorkResult.new(result: 84, work: work)

      cache.set(work, result)

      expect(cache.has?(work)).to be true
    end

    it "returns false when work is not cached" do
      cache = described_class.new
      work = CachedWork.new(42)

      expect(cache.has?(work)).to be false
    end

    it "returns false for expired entries" do
      cache = described_class.new(ttl: 0.1) # 100ms TTL
      work = CachedWork.new(42)
      result = Fractor::WorkResult.new(result: 84, work: work)

      cache.set(work, result)
      sleep 0.15 # Wait for expiration

      expect(cache.has?(work)).to be false
    end
  end

  describe "#set" do
    it "stores a result in the cache" do
      cache = described_class.new
      work = CachedWork.new(42)
      result = Fractor::WorkResult.new(result: 84, work: work)

      cache.set(work, result)

      expect(cache.size).to eq(1)
      expect(cache.has?(work)).to be true
    end
  end

  describe "#invalidate" do
    it "removes a cached result" do
      cache = described_class.new
      work = CachedWork.new(42)
      result = Fractor::WorkResult.new(result: 84, work: work)

      cache.set(work, result)
      expect(cache.has?(work)).to be true

      result = cache.invalidate(work)

      expect(result).to be true
      expect(cache.has?(work)).to be false
    end

    it "returns false when result is not cached" do
      cache = described_class.new
      work = CachedWork.new(42)

      result = cache.invalidate(work)

      expect(result).to be false
    end
  end

  describe "#clear" do
    it "removes all cached results" do
      cache = described_class.new
      work1 = CachedWork.new(1)
      work2 = CachedWork.new(2)

      cache.set(work1, Fractor::WorkResult.new(result: 2, work: work1))
      cache.set(work2, Fractor::WorkResult.new(result: 4, work: work2))

      expect(cache.size).to eq(2)

      cache.clear

      expect(cache.size).to eq(0)
      expect(cache.has?(work1)).to be false
      expect(cache.has?(work2)).to be false
    end
  end

  describe "#stats" do
    it "returns cache statistics" do
      cache = described_class.new
      work = CachedWork.new(42)
      result = Fractor::WorkResult.new(result: 84, work: work)

      cache.set(work, result)
      cache.get(work) { raise "Should not be called" }

      stats = cache.stats

      expect(stats[:size]).to eq(1)
      expect(stats[:hits]).to eq(1)
      expect(stats[:misses]).to eq(0)
      expect(stats[:hit_rate]).to eq(100.0)
    end

    it "calculates hit rate correctly" do
      cache = described_class.new
      work1 = CachedWork.new(1)
      work2 = CachedWork.new(2)

      # First hit
      cache.set(work1, Fractor::WorkResult.new(result: 2, work: work1))
      cache.get(work1) { raise "Should not be called" }

      # First miss
      cache.get(work2) { Fractor::WorkResult.new(result: 4, work: work2) }

      stats = cache.stats

      expect(stats[:hits]).to eq(1)
      expect(stats[:misses]).to eq(1)
      expect(stats[:hit_rate]).to eq(50.0)
    end
  end

  describe "#cleanup_expired" do
    it "removes expired entries" do
      cache = described_class.new(ttl: 0.1) # 100ms TTL
      work1 = CachedWork.new(1)
      work2 = CachedWork.new(2)

      cache.set(work1, Fractor::WorkResult.new(result: 2, work: work1))
      cache.set(work2, Fractor::WorkResult.new(result: 4, work: work2))

      sleep 0.15 # Wait for expiration

      removed = cache.cleanup_expired

      expect(removed).to eq(2)
      expect(cache.size).to eq(0)
    end

    it "keeps non-expired entries" do
      cache = described_class.new(ttl: 10) # 10 second TTL
      work1 = CachedWork.new(1)
      work2 = CachedWork.new(2)

      cache.set(work1, Fractor::WorkResult.new(result: 2, work: work1))
      cache.set(work2, Fractor::WorkResult.new(result: 4, work: work2))

      removed = cache.cleanup_expired

      expect(removed).to eq(0)
      expect(cache.size).to eq(2)
    end
  end

  describe "max_size limit" do
    it "evicts oldest entry when limit is reached" do
      cache = described_class.new(max_size: 2)
      work1 = CachedWork.new(1)
      work2 = CachedWork.new(2)
      work3 = CachedWork.new(3)

      cache.set(work1, Fractor::WorkResult.new(result: 2, work: work1))
      cache.set(work2, Fractor::WorkResult.new(result: 4, work: work2))
      expect(cache.size).to eq(2)

      # Adding third entry should evict the first (LRU)
      cache.set(work3, Fractor::WorkResult.new(result: 6, work: work3))

      expect(cache.size).to eq(2)
      expect(cache.has?(work1)).to be false  # Evicted
      expect(cache.has?(work2)).to be true   # Still present
      expect(cache.has?(work3)).to be true   # Newly added
    end
  end

  describe "with timeout-enabled work items" do
    it "generates different cache keys for different timeouts" do
      cache = described_class.new
      work1 = Fractor::Work.new({ value: 42 }, timeout: 10)
      work2 = Fractor::Work.new({ value: 42 }, timeout: 20)

      result1 = Fractor::WorkResult.new(result: 84, work: work1)
      result2 = Fractor::WorkResult.new(result: 84, work: work2)

      cache.set(work1, result1)
      cache.set(work2, result2)

      # Same input but different timeout = different cache entries
      expect(cache.size).to eq(2)
    end

    it "generates same cache key for same timeout" do
      cache = described_class.new
      work1 = Fractor::Work.new({ value: 42 }, timeout: 10)
      work2 = Fractor::Work.new({ value: 42 }, timeout: 10)

      result = Fractor::WorkResult.new(result: 84, work: work1)

      cache.set(work1, result)
      expect(cache.get(work2) { raise "Should not be called" }).to eq(result)
      expect(cache.size).to eq(1)
    end

    it "handles work without timeout" do
      cache = described_class.new
      work1 = Fractor::Work.new({ value: 42 })
      work2 = Fractor::Work.new({ value: 42 }, timeout: nil)

      result = Fractor::WorkResult.new(result: 84, work: work1)

      cache.set(work1, result)
      # Work without timeout should match work with nil timeout
      expect(cache.get(work2) { raise "Should not be called" }).to eq(result)
    end
  end
end
