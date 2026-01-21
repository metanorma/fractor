# frozen_string_literal: true

require "spec_helper"

RSpec.describe Fractor::Worker do
  describe ".timeout" do
    it "sets a class-level timeout" do
      test_worker_class = Class.new(Fractor::Worker) do
        timeout 5
      end

      expect(test_worker_class.worker_timeout).to eq(5)
    end

    it "can be chained with other class methods" do
      test_worker_class = Class.new(Fractor::Worker) do
        timeout 10

        def process(work)
          Fractor::WorkResult.new(result: work.input * 2, work: work)
        end
      end

      expect(test_worker_class.worker_timeout).to eq(10)
    end
  end

  describe ".effective_timeout" do
    before do
      # Reset configuration
      Fractor.configure do |config|
        config.default_worker_timeout = 120
      end
    end

    after do
      # Reset configuration after tests
      Fractor.configure do |config|
        config.default_worker_timeout = 120
      end
    end

    it "returns class-level timeout when set" do
      test_worker_class = Class.new(Fractor::Worker) do
        timeout 30
      end

      expect(test_worker_class.effective_timeout).to eq(30)
    end

    it "returns global default when class timeout not set" do
      test_worker_class = Class.new(described_class)

      expect(test_worker_class.effective_timeout).to eq(120)
    end

    it "returns nil when neither class timeout nor global default are set" do
      test_worker_class = Class.new(described_class)

      Fractor.configure do |config|
        config.default_worker_timeout = nil
      end

      expect(test_worker_class.effective_timeout).to be_nil
    end
  end

  describe "#timeout" do
    let(:worker_class) do
      Class.new(Fractor::Worker) do
        timeout 10

        def process(work)
          Fractor::WorkResult.new(result: work.input * 2, work: work)
        end
      end
    end

    it "returns class-level timeout by default" do
      worker = worker_class.new
      expect(worker.timeout).to eq(10)
    end

    it "returns instance-level timeout when set via options" do
      worker = worker_class.new(timeout: 5)
      expect(worker.timeout).to eq(5)
    end

    it "returns class-level timeout when instance option is nil" do
      worker = worker_class.new(timeout: nil)
      expect(worker.timeout).to eq(10)
    end
  end
end

# Integration tests for timeout with actual Ractor execution
RSpec.describe "Worker timeout integration" do
  # Worker that completes quickly
  class QuickTimeoutWorker < Fractor::Worker
    def process(work)
      Fractor::WorkResult.new(result: work.input[:value] * 2, work: work)
    end
  end

  # Worker that times out (sleeps longer than timeout)
  class SlowTimeoutWorker < Fractor::Worker
    timeout 0.5 # 0.5 second timeout for testing

    def process(work)
      sleep 2 # Sleep longer than the timeout
      Fractor::WorkResult.new(result: work.input[:value] * 2, work: work)
    end
  end

  # Worker with custom timeout
  class CustomTimeoutWorker < Fractor::Worker
    timeout 5 # 5 second timeout

    def process(work)
      sleep 0.1 # Quick operation
      Fractor::WorkResult.new(result: work.input[:value] * 2, work: work)
    end
  end

  # Work class for testing
  class TimeoutWork < Fractor::Work
    def initialize(value)
      super({ value: value })
    end
  end

  describe "with class-level timeout" do
    it "processes work that completes within timeout" do
      supervisor = Fractor::Supervisor.new(
        worker_pools: [{ worker_class: CustomTimeoutWorker, num_workers: 1 }],
        debug: false,
      )

      supervisor.add_work_item(TimeoutWork.new(10))
      supervisor.run

      expect(supervisor.results.results.size).to eq(1)
      expect(supervisor.results.results.first.result).to eq(20)
      expect(supervisor.results.errors).to be_empty
    end

    it "returns timeout error for work that exceeds class timeout" do
      supervisor = Fractor::Supervisor.new(
        worker_pools: [{ worker_class: SlowTimeoutWorker, num_workers: 1 }],
        debug: false,
      )

      supervisor.add_work_item(TimeoutWork.new(5))
      supervisor.run

      expect(supervisor.results.errors.size).to eq(1)
      error_result = supervisor.results.errors.first

      expect(error_result.error).to include("timeout")
      expect(error_result.error_category).to eq(:timeout)
      expect(error_result.retriable?).to be true
    end

    it "processes work without timeout when worker has no timeout" do
      supervisor = Fractor::Supervisor.new(
        worker_pools: [{ worker_class: QuickTimeoutWorker, num_workers: 1 }],
        debug: false,
      )

      supervisor.add_work_item(TimeoutWork.new(21))
      supervisor.run

      expect(supervisor.results.results.size).to eq(1)
      expect(supervisor.results.results.first.result).to eq(42)
      expect(supervisor.results.errors).to be_empty
    end
  end
end
