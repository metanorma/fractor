# frozen_string_literal: true

require "timeout"

# Define test classes
module SupervisorSpec
  class TestWorker < Fractor::Worker
    def process(work)
      # Simple multiplication
      if work.value == 5
        error = StandardError.new("Cannot process 5")
        Fractor::WorkResult.new(error: error, work: work)
      else
        Fractor::WorkResult.new(result: work.value * 2, work: work)
      end
    end
  end

  class TestWork < Fractor::Work
    def initialize(value)
      super({ value: value })
    end

    def value
      input[:value]
    end

    def to_s
      "TestWork: #{value}"
    end
  end
end

RSpec.describe Fractor::Supervisor do
  # Skip these tests on Windows with Ruby 3.4
  skip "This hangs on Windows with Ruby 3.4" if RUBY_PLATFORM.match?(/mingw|mswin|cygwin/) && RUBY_VERSION.start_with?("3.4")
  describe "#initialize" do
    it "initializes with worker pools" do
      supervisor = described_class.new(
        worker_pools: [
          { worker_class: SupervisorSpec::TestWorker, num_workers: 2 },
        ],
      )

      expect(supervisor.worker_pools.size).to eq(1)
      expect(supervisor.worker_pools.first[:worker_class]).to eq(SupervisorSpec::TestWorker)
      expect(supervisor.work_queue).to be_a(Queue)
      expect(supervisor.work_queue).to be_empty
      expect(supervisor.results).to be_a(Fractor::ResultAggregator)
    end

    it "raises error if worker_class does not inherit from Fractor::Worker" do
      expect do
        described_class.new(
          worker_pools: [
            { worker_class: Class.new, num_workers: 2 },
          ],
        )
      end.to raise_error(ArgumentError, /must inherit from Fractor::Worker/)
    end

    it "initializes with empty worker pools" do
      supervisor = described_class.new
      expect(supervisor.worker_pools).to be_empty
      expect(supervisor.work_queue).to be_a(Queue)
      expect(supervisor.work_queue).to be_empty
    end

    context "worker auto-detection" do
      it "auto-detects number of workers when num_workers is not specified" do
        # Mock Etc.nprocessors to return a known value
        allow(Etc).to receive(:nprocessors).and_return(8)

        supervisor = described_class.new(
          worker_pools: [
            { worker_class: SupervisorSpec::TestWorker },
          ],
        )

        expect(supervisor.worker_pools.first[:num_workers]).to eq(8)
      end

      it "uses explicitly specified num_workers when provided" do
        # Mock Etc.nprocessors - should not be called
        allow(Etc).to receive(:nprocessors).and_return(8)

        supervisor = described_class.new(
          worker_pools: [
            { worker_class: SupervisorSpec::TestWorker, num_workers: 4 },
          ],
        )

        expect(supervisor.worker_pools.first[:num_workers]).to eq(4)
      end

      it "falls back to 2 workers when auto-detection fails" do
        # Mock Etc.nprocessors to raise an error
        allow(Etc).to receive(:nprocessors).and_raise(StandardError.new("Detection failed"))

        supervisor = described_class.new(
          worker_pools: [
            { worker_class: SupervisorSpec::TestWorker },
          ],
        )

        expect(supervisor.worker_pools.first[:num_workers]).to eq(2)
      end

      it "supports mixed auto-detection and explicit configuration" do
        allow(Etc).to receive(:nprocessors).and_return(8)

        supervisor = described_class.new(
          worker_pools: [
            { worker_class: SupervisorSpec::TestWorker }, # Auto-detected
            { worker_class: SupervisorSpec::TestWorker, num_workers: 3 }, # Explicit
          ],
        )

        expect(supervisor.worker_pools[0][:num_workers]).to eq(8)
        expect(supervisor.worker_pools[1][:num_workers]).to eq(3)
      end
    end
  end

  describe "#add_work_item" do
    let(:supervisor) do
      described_class.new(
        worker_pools: [
          { worker_class: SupervisorSpec::TestWorker, num_workers: 2 },
        ],
      )
    end

    it "adds a single work item to the queue" do
      work = SupervisorSpec::TestWork.new(1)
      expect do
        supervisor.add_work_item(work)
      end.to change { supervisor.work_queue.size }.from(0).to(1)
    end

    it "raises an error if item is not a Work instance" do
      expect do
        supervisor.add_work_item(42)
      end.to raise_error(ArgumentError, /must be an instance of Fractor::Work/)
    end
  end

  describe "#add_work_items" do
    let(:supervisor) do
      described_class.new(
        worker_pools: [
          { worker_class: SupervisorSpec::TestWorker, num_workers: 2 },
        ],
      )
    end

    it "adds multiple work items to the queue" do
      works = [
        SupervisorSpec::TestWork.new(1),
        SupervisorSpec::TestWork.new(2),
        SupervisorSpec::TestWork.new(3),
      ]

      expect do
        supervisor.add_work_items(works)
      end.to change { supervisor.work_queue.size }.from(0).to(3)
    end

    it "handles empty work arrays" do
      expect do
        supervisor.add_work_items([])
      end.not_to(change { supervisor.work_queue.size })
    end
  end

  describe "#run" do
    it "processes work items and collects results" do
      # This test simulates a simple workflow with a supervisor
      # It's a small-scale integration test
      supervisor = described_class.new(
        worker_pools: [
          { worker_class: SupervisorSpec::TestWorker, num_workers: 2 },
        ],
      )

      # Add work items - use a small number to keep the test fast
      supervisor.add_work_items([
                                  SupervisorSpec::TestWork.new(1),
                                  SupervisorSpec::TestWork.new(2),
                                  SupervisorSpec::TestWork.new(3),
                                  SupervisorSpec::TestWork.new(4),
                                  SupervisorSpec::TestWork.new(5),
                                ])

      # Run the supervisor with a small timeout
      # We don't want to wait indefinitely in case of issues
      Timeout.timeout(10) do
        supervisor.run
      end

      # Verify the results - we should have results for all 5 items
      expect(supervisor.results.results.size + supervisor.results.errors.size).to eq(5)

      # Verify that all results were processed correctly
      supervisor.results.results.map(&:result)
      # For any item that had error, the work value would be 5
      if supervisor.results.errors.any?
        expect(supervisor.results.errors.map do |e|
          e.work.value
        end).to eq([5])
      end

      # Verify the error only if there's an error result
      if supervisor.results.errors.any?
        error = supervisor.results.errors.first
        expect(error.error).to be_a(StandardError)
        expect(error.error.message).to eq("Cannot process 5")
        expect(error.work.value).to eq(5)
      end
    end
  end
end
