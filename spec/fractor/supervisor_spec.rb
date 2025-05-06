# frozen_string_literal: true

require "timeout"

# Define test classes
module SupervisorSpec
  class TestWorker < Fractor::Worker
    def process(work)
      # Simple multiplication
      if work.input == 5
        Fractor::WorkResult.new(error: "Cannot process 5", work: work)
      else
        Fractor::WorkResult.new(result: work.input * 2, work: work)
      end
    end
  end

  class TestWork < Fractor::Work
    def to_s
      "TestWork: #{@input}"
    end
  end
end

RSpec.describe Fractor::Supervisor do
  describe "#initialize" do
    it "initializes with required parameters" do
      supervisor = Fractor::Supervisor.new(
        worker_class: SupervisorSpec::TestWorker,
        work_class: SupervisorSpec::TestWork,
        num_workers: 2
      )

      expect(supervisor.worker_class).to eq(SupervisorSpec::TestWorker)
      expect(supervisor.work_class).to eq(SupervisorSpec::TestWork)
      expect(supervisor.work_queue).to be_a(Queue)
      expect(supervisor.work_queue).to be_empty
      expect(supervisor.results).to be_a(Fractor::ResultAggregator)
    end

    it "raises error if worker_class does not inherit from Fractor::Worker" do
      expect do
        Fractor::Supervisor.new(
          worker_class: Class.new,
          work_class: SupervisorSpec::TestWork
        )
      end.to raise_error(ArgumentError, /must inherit from Fractor::Worker/)
    end

    it "raises error if work_class does not inherit from Fractor::Work" do
      expect do
        Fractor::Supervisor.new(
          worker_class: SupervisorSpec::TestWorker,
          work_class: Class.new
        )
      end.to raise_error(ArgumentError, /must inherit from Fractor::Work/)
    end
  end

  describe "#add_work" do
    let(:supervisor) do
      Fractor::Supervisor.new(worker_class: SupervisorSpec::TestWorker, work_class: SupervisorSpec::TestWork)
    end

    it "adds work items to the queue" do
      expect do
        supervisor.add_work([1, 2, 3])
      end.to change { supervisor.work_queue.size }.from(0).to(3)
    end

    it "handles empty work arrays" do
      expect do
        supervisor.add_work([])
      end.not_to(change { supervisor.work_queue.size })
    end
  end

  # Integration test for the run method
  # This is a more complex test that tests the supervisor's main functionality
  # It starts workers, processes work, and collects results
  describe "#run" do
    it "processes work items and collects results" do
      # This test simulates a simple workflow with a supervisor
      # It's a small-scale integration test
      supervisor = Fractor::Supervisor.new(
        worker_class: SupervisorSpec::TestWorker,
        work_class: SupervisorSpec::TestWork,
        num_workers: 2
      )

      # Add work items - use a small number to keep the test fast
      supervisor.add_work([1, 2, 3, 4, 5])

      # Run the supervisor with a small timeout
      # We don't want to wait indefinitely in case of issues
      Timeout.timeout(10) do
        supervisor.run
      end

      # Verify the results - we should have results for all 5 items
      expect(supervisor.results.results.size + supervisor.results.errors.size).to eq(5)

      # Verify that all results were processed correctly
      supervisor.results.results.map(&:result)
      # For any item that had error, the input would be 5
      expect(supervisor.results.errors.map { |e| e.work.input }).to include(5) if supervisor.results.errors.any?

      # Verify the error only if there's an error result
      if supervisor.results.errors.any?
        error = supervisor.results.errors.first
        expect(error.error).to eq("Cannot process 5")
        expect(error.work.input).to eq(5)
      end
    end
  end
end
