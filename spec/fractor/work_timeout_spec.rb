# frozen_string_literal: true

require "spec_helper"

RSpec.describe Fractor::Work do
  describe "#timeout" do
    it "accepts timeout parameter" do
      work = described_class.new("test", timeout: 10)
      expect(work.timeout).to eq(10)
    end

    it "defaults to nil when no timeout specified" do
      work = described_class.new("test")
      expect(work.timeout).to be_nil
    end

    it "can set timeout to 0" do
      work = described_class.new("test", timeout: 0)
      expect(work.timeout).to eq(0)
    end

    it "includes timeout in inspect when set" do
      work = described_class.new("test", timeout: 5)
      expect(work.inspect).to include("@timeout=5")
    end

    it "does not include timeout in inspect when nil" do
      work = described_class.new("test")
      expect(work.inspect).not_to include("@timeout")
    end
  end

  describe "#initialize" do
    it "supports keyword argument for timeout" do
      work = described_class.new({ data: "value" }, timeout: 30)
      expect(work.input).to eq({ data: "value" })
      expect(work.timeout).to eq(30)
    end

    it "allows timeout to be omitted for backward compatibility" do
      work = described_class.new("simple input")
      expect(work.input).to eq("simple input")
      expect(work.timeout).to be_nil
    end
  end
end

# Integration tests for per-work-item timeout with actual Ractor execution
RSpec.describe "Per-work-item timeout integration" do
  # Worker with class-level timeout
  class WorkerWithClassTimeout < Fractor::Worker
    timeout 10 # 10 second class-level timeout

    def process(work)
      sleep 0.1
      Fractor::WorkResult.new(result: work.input[:value] * 2, work: work)
    end
  end

  # Worker without class-level timeout
  class WorkerWithoutTimeout < Fractor::Worker
    def process(work)
      sleep 0.1
      Fractor::WorkResult.new(result: work.input[:value] * 2, work: work)
    end
  end

  # Worker that simulates slow work
  class SlowWorker < Fractor::Worker
    def process(work)
      sleep 2
      Fractor::WorkResult.new(result: work.input[:value] * 2, work: work)
    end
  end

  # Work class with timeout support
  class WorkWithTimeout < Fractor::Work
    def initialize(value, timeout: nil)
      super({ value: value }, timeout: timeout)
    end
  end

  describe "work timeout overrides worker timeout" do
    it "uses work-specific timeout when shorter than worker timeout" do
      supervisor = Fractor::Supervisor.new(
        worker_pools: [{ worker_class: SlowWorker, num_workers: 1 }],
        debug: false,
      )

      # Work with 0.5 second timeout (shorter than worker's default)
      work = WorkWithTimeout.new(10, timeout: 0.5)
      supervisor.add_work_item(work)
      supervisor.run

      # Should timeout since 0.5s < 2s sleep time
      expect(supervisor.results.errors.size).to eq(1)
      error_result = supervisor.results.errors.first
      expect(error_result.error).to include("timeout")
      expect(error_result.error_category).to eq(:timeout)
    end

    it "uses worker timeout when work timeout is nil" do
      supervisor = Fractor::Supervisor.new(
        worker_pools: [{ worker_class: WorkerWithClassTimeout, num_workers: 1 }],
        debug: false,
      )

      # Work with no timeout specified (uses worker's 10s timeout)
      work = WorkWithTimeout.new(5)
      supervisor.add_work_item(work)
      supervisor.run

      # Should complete since 0.1s sleep < 10s worker timeout
      expect(supervisor.results.results.size).to eq(1)
      expect(supervisor.results.results.first.result).to eq(10)
    end

    it "uses work timeout when worker has no class timeout" do
      supervisor = Fractor::Supervisor.new(
        worker_pools: [{ worker_class: WorkerWithoutTimeout, num_workers: 1 }],
        debug: false,
      )

      # Work with 0.5 second timeout (worker has no timeout)
      work = WorkWithTimeout.new(7, timeout: 0.5)
      supervisor.add_work_item(work)
      supervisor.run

      # Should complete since 0.1s sleep < 0.5s work timeout
      expect(supervisor.results.results.size).to eq(1)
      expect(supervisor.results.results.first.result).to eq(14)
    end

    it "processes work with no timeout when neither work nor worker have timeout" do
      supervisor = Fractor::Supervisor.new(
        worker_pools: [{ worker_class: WorkerWithoutTimeout, num_workers: 1 }],
        debug: false,
      )

      work = WorkWithTimeout.new(21)
      supervisor.add_work_item(work)
      supervisor.run

      expect(supervisor.results.results.size).to eq(1)
      expect(supervisor.results.results.first.result).to eq(42)
    end
  end

  describe "mixed timeout work items" do
    it "processes work items with different timeouts in same supervisor" do
      supervisor = Fractor::Supervisor.new(
        worker_pools: [{ worker_class: SlowWorker, num_workers: 2 }],
        debug: false,
      )

      # Mix of work items with different timeouts
      fast_work = WorkWithTimeout.new(1, timeout: 5) # 5s timeout - completes
      slow_work = WorkWithTimeout.new(2, timeout: 0.3) # 0.3s timeout - times out
      no_timeout_work = WorkWithTimeout.new(3) # No timeout - completes

      supervisor.add_work_items([fast_work, slow_work, no_timeout_work])
      supervisor.run

      # fast_work completes (0.1s < 5s)
      # slow_work times out (2s > 0.3s)
      # no_timeout_work completes (no timeout limit)
      expect(supervisor.results.results.size).to eq(2)
      expect(supervisor.results.errors.size).to eq(1)

      # The error should be the slow work
      error_result = supervisor.results.errors.first
      expect(error_result.error).to include("timeout")
    end
  end
end
