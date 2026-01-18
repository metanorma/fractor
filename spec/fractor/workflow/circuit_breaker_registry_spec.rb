# frozen_string_literal: true

require "spec_helper"
require_relative "../../../lib/fractor/workflow/circuit_breaker"
require_relative "../../../lib/fractor/workflow/circuit_breaker_registry"

RSpec.describe Fractor::Workflow::CircuitBreakerRegistry do
  let(:registry) { described_class.new }

  describe "#get_or_create" do
    it "creates a new circuit breaker with default options" do
      breaker = registry.get_or_create("test_key")
      expect(breaker).to be_a(Fractor::Workflow::CircuitBreaker)
      expect(breaker.threshold).to eq(5)
      expect(breaker.timeout).to eq(60)
    end

    it "creates a new circuit breaker with custom options" do
      breaker = registry.get_or_create("test_key", threshold: 3, timeout: 30)
      expect(breaker.threshold).to eq(3)
      expect(breaker.timeout).to eq(30)
    end

    it "returns the same circuit breaker for the same key" do
      breaker1 = registry.get_or_create("test_key", threshold: 3)
      breaker2 = registry.get_or_create("test_key", threshold: 5)

      expect(breaker1).to be(breaker2)
      expect(breaker1.threshold).to eq(3) # Original options preserved
    end

    it "creates different circuit breakers for different keys" do
      breaker1 = registry.get_or_create("key1")
      breaker2 = registry.get_or_create("key2")

      expect(breaker1).not_to be(breaker2)
    end

    it "is thread-safe" do
      threads = Array.new(10) do
        Thread.new do
          registry.get_or_create("concurrent_key")
        end
      end

      breakers = threads.map(&:value)
      expect(breakers.uniq.size).to eq(1)
    end
  end

  describe "#get" do
    it "returns nil for non-existent key" do
      expect(registry.get("nonexistent")).to be_nil
    end

    it "returns the circuit breaker for existing key" do
      created = registry.get_or_create("test_key")
      retrieved = registry.get("test_key")

      expect(retrieved).to be(created)
    end
  end

  describe "#remove" do
    it "removes and returns the circuit breaker" do
      breaker = registry.get_or_create("test_key")
      removed = registry.remove("test_key")

      expect(removed).to be(breaker)
      expect(registry.get("test_key")).to be_nil
    end

    it "returns nil when removing non-existent key" do
      expect(registry.remove("nonexistent")).to be_nil
    end
  end

  describe "#reset_all" do
    it "resets all circuit breakers in the registry" do
      # Create and open multiple circuit breakers
      breaker1 = registry.get_or_create("key1", threshold: 1)
      breaker2 = registry.get_or_create("key2", threshold: 1)

      # Trigger failures to open circuits
      expect do
        breaker1.call do
          raise StandardError
        end
      end.to raise_error(StandardError)
      expect do
        breaker2.call do
          raise StandardError
        end
      end.to raise_error(StandardError)

      expect(breaker1).to be_open
      expect(breaker2).to be_open

      # Reset all
      registry.reset_all

      expect(breaker1).to be_closed
      expect(breaker2).to be_closed
      expect(breaker1.failure_count).to eq(0)
      expect(breaker2.failure_count).to eq(0)
    end

    it "handles empty registry" do
      expect { registry.reset_all }.not_to raise_error
    end
  end

  describe "#all_stats" do
    it "returns empty hash for empty registry" do
      expect(registry.all_stats).to eq({})
    end

    it "returns stats for all circuit breakers" do
      registry.get_or_create("key1", threshold: 3)
      registry.get_or_create("key2", threshold: 5)

      stats = registry.all_stats

      expect(stats.keys).to contain_exactly("key1", "key2")
      expect(stats["key1"][:threshold]).to eq(3)
      expect(stats["key2"][:threshold]).to eq(5)
    end

    it "includes current state in stats" do
      breaker = registry.get_or_create("key1", threshold: 1)
      expect do
        breaker.call do
          raise StandardError
        end
      end.to raise_error(StandardError)

      stats = registry.all_stats
      expect(stats["key1"][:state]).to eq(:open)
      expect(stats["key1"][:failure_count]).to eq(1)
    end
  end

  describe "#clear" do
    it "removes all circuit breakers" do
      registry.get_or_create("key1")
      registry.get_or_create("key2")
      registry.get_or_create("key3")

      expect(registry.all_stats.size).to eq(3)

      registry.clear

      expect(registry.all_stats).to be_empty
      expect(registry.get("key1")).to be_nil
      expect(registry.get("key2")).to be_nil
      expect(registry.get("key3")).to be_nil
    end

    it "handles empty registry" do
      expect { registry.clear }.not_to raise_error
      expect(registry.all_stats).to be_empty
    end
  end

  describe "shared circuit breaker usage" do
    it "allows multiple jobs to share a circuit breaker" do
      shared_breaker = registry.get_or_create("shared_api", threshold: 3)

      # Job 1 causes failures
      2.times do
        expect do
          shared_breaker.call do
            raise StandardError
          end
        end.to raise_error(StandardError)
      end

      expect(shared_breaker.failure_count).to eq(2)

      # Job 2 contributes to same circuit breaker
      expect do
        shared_breaker.call do
          raise StandardError
        end
      end.to raise_error(StandardError)

      # Circuit should now be open
      expect(shared_breaker).to be_open
    end

    it "isolates circuit breakers with different keys" do
      api1_breaker = registry.get_or_create("api1", threshold: 2)
      api2_breaker = registry.get_or_create("api2", threshold: 2)

      # Open api1 circuit
      2.times do
        expect do
          api1_breaker.call do
            raise StandardError
          end
        end.to raise_error(StandardError)
      end

      expect(api1_breaker).to be_open
      expect(api2_breaker).to be_closed

      # api2 should still work
      result = api2_breaker.call { "success" }
      expect(result).to eq("success")
    end
  end
end
