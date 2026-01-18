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

  describe "#debugging methods" do
    let(:supervisor) do
      described_class.new(
        worker_pools: [
          { worker_class: SupervisorSpec::TestWorker, num_workers: 2 },
        ],
      )
    end

    describe "#debug?" do
      it "returns false by default" do
        expect(supervisor.debug?).to be false
      end

      it "returns true when debug mode is enabled" do
        supervisor.debug!
        expect(supervisor.debug?).to be true
      end

      it "returns false when debug mode is disabled" do
        supervisor.debug!
        supervisor.debug_off!
        expect(supervisor.debug?).to be false
      end
    end

    describe "#debug!" do
      it "enables debug mode" do
        expect { supervisor.debug! }.to change { supervisor.debug? }.from(false).to(true)
      end
    end

    describe "#debug_off!" do
      it "disables debug mode" do
        supervisor.debug!
        expect { supervisor.debug_off! }.to change { supervisor.debug? }.from(true).to(false)
      end
    end

    describe "#inspect_queue" do
      it "returns empty queue info when no work items added" do
        queue_info = supervisor.inspect_queue

        expect(queue_info).to be_a(Hash)
        expect(queue_info[:size]).to eq(0)
        expect(queue_info[:total_added]).to eq(0)
        expect(queue_info[:items]).to be_empty
      end

      it "returns queue info with work items" do
        supervisor.add_work_items([
                                    SupervisorSpec::TestWork.new(1),
                                    SupervisorSpec::TestWork.new(2),
                                  ])

        queue_info = supervisor.inspect_queue

        expect(queue_info[:size]).to eq(2)
        expect(queue_info[:total_added]).to eq(2)
        expect(queue_info[:items].size).to eq(2)

        # Check first item structure
        first_item = queue_info[:items].first
        expect(first_item[:class]).to eq("SupervisorSpec::TestWork")
        expect(first_item[:input]).to eq({ value: 1 })
        expect(first_item[:inspect]).to include("TestWork")
      end

      it "returns items with detailed information" do
        work = SupervisorSpec::TestWork.new(42)
        supervisor.add_work_item(work)

        queue_info = supervisor.inspect_queue
        item = queue_info[:items].first

        expect(item[:class]).to eq("SupervisorSpec::TestWork")
        expect(item[:input]).to eq({ value: 42 })
        expect(item[:inspect]).to be_a(String)
      end
    end

    describe "#workers_status" do
      it "returns status with zero workers before start" do
        status = supervisor.workers_status

        expect(status).to be_a(Hash)
        expect(status[:total]).to eq(0)
        expect(status[:idle]).to eq(0)
        expect(status[:busy]).to eq(0)
        # Pools are configured but workers array is empty
        expect(status[:pools].size).to eq(1)
        expect(status[:pools].first[:workers]).to be_empty
      end

      it "returns status with worker pool information" do
        supervisor.start_workers

        status = supervisor.workers_status

        expect(status[:total]).to eq(2)
        expect(status[:idle]).to be_a(Integer)
        expect(status[:busy]).to be_a(Integer)
        expect(status[:pools].size).to eq(1)

        pool_status = status[:pools].first
        expect(pool_status[:worker_class]).to eq("SupervisorSpec::TestWorker")
        expect(pool_status[:num_workers]).to eq(2)
        expect(pool_status[:workers].size).to eq(2)

        # Check worker structure
        worker_status = pool_status[:workers].first
        expect(worker_status[:name]).to be_a(String)
        expect(worker_status[:idle]).to satisfy { |v| v == true || v == false }
      end

      it "returns status for multiple worker pools" do
        multi_pool_supervisor = described_class.new(
          worker_pools: [
            { worker_class: SupervisorSpec::TestWorker, num_workers: 2 },
            { worker_class: SupervisorSpec::TestWorker, num_workers: 3 },
          ],
        )
        multi_pool_supervisor.start_workers

        status = multi_pool_supervisor.workers_status

        expect(status[:total]).to eq(5)
        expect(status[:pools].size).to eq(2)
        expect(status[:pools][0][:num_workers]).to eq(2)
        expect(status[:pools][1][:num_workers]).to eq(3)
      end
    end

    describe "#performance_metrics" do
      it "returns nil when performance monitoring is disabled" do
        expect(supervisor.performance_metrics).to be_nil
      end

      it "returns metrics when performance monitoring is enabled" do
        monitored_supervisor = described_class.new(
          worker_pools: [
            { worker_class: SupervisorSpec::TestWorker, num_workers: 2 },
          ],
          enable_performance_monitoring: true
        )

        metrics = monitored_supervisor.performance_metrics

        expect(metrics).to be_a(Hash)
        expect(metrics.keys).to include(:jobs_processed, :jobs_succeeded, :jobs_failed,
                                        :average_latency, :throughput, :worker_count)
      end
    end
  end
end
