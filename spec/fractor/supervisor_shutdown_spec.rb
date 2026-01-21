# frozen_string_literal: true

require "spec_helper"
require "timeout"

RSpec.describe "Fractor::Supervisor Shutdown Scenarios" do
  let(:worker_class) do
    Class.new(Fractor::Worker) do
      def process(work)
        # Extract value from work input
        value = work.input[:value]
        Fractor::WorkResult.new(result: value * 2, work: work)
      end
    end
  end

  let(:work_class) do
    Class.new(Fractor::Work) do
      def initialize(value)
        super({ value: value })
      end

      def value
        input[:value]
      end
    end
  end

  describe "work distribution regression tests" do
    it "properly distributes work added before run() is called" do
      # Regression test for stale workers array reference bug
      # Previously, WorkDistributionManager held a reference to the empty @workers array
      # from initialization, and didn't get updated when @workers was reassigned in start_workers
      supervisor = Fractor::Supervisor.new(
        worker_pools: [
          { worker_class: worker_class, num_workers: 2 },
        ],
        debug: false,
      )

      # Add work BEFORE calling run
      3.times { |i| supervisor.add_work_item(work_class.new(i + 1)) }

      # Start supervisor - this should trigger initial work distribution
      supervisor_thread = Thread.new do
        supervisor.run
      end

      # Wait a moment for work to be processed
      sleep(0.5)

      # Stop the supervisor
      supervisor.stop
      supervisor_thread.join(2)

      # Verify work was actually processed (not stuck in queue)
      total_processed = supervisor.results.results.size + supervisor.results.errors.size
      expect(total_processed).to eq(3),
                                 "Expected all 3 work items to be processed, but got #{total_processed}"
    end

    it "updates work_distribution_manager workers reference after start_workers" do
      # Direct test that the WorkDistributionManager's workers reference is updated
      supervisor = Fractor::Supervisor.new(
        worker_pools: [
          { worker_class: worker_class, num_workers: 2 },
        ],
        debug: false,
      )

      # Before start_workers, the workers array should be empty
      expect(supervisor.workers).to be_empty

      # Start workers
      supervisor.start_workers

      # After start_workers, workers should be populated
      expect(supervisor.workers.size).to eq(2)

      # WorkDistributionManager should have the updated workers reference
      # This is verified indirectly through idle_workers list
      expect(supervisor.instance_variable_get(:@work_distribution_manager).idle_workers.size).to eq(2)
    end
  end

  describe "graceful shutdown in continuous mode" do
    it "stops processing when stop is called" do
      supervisor = Fractor::Supervisor.new(
        worker_pools: [
          { worker_class: worker_class, num_workers: 2 },
        ],
        continuous_mode: true,
        debug: false,
      )

      # Register a work source that provides work continuously
      work_count = [0]
      supervisor.register_work_source do
        if work_count[0] < 5
          work_count[0] += 1
          [work_class.new(work_count[0])]
        else
          []
        end
      end

      # Start supervisor in a thread
      supervisor_thread = Thread.new do
        supervisor.run
      end

      # Wait for some work to be processed
      sleep(0.5)

      # Stop the supervisor
      supervisor.stop

      # Wait for thread to finish
      supervisor_thread.join(2)

      # Verify supervisor is stopped (thread finished without hanging)
      expect(supervisor_thread.alive?).to be false
    end

    it "processes queued work before stopping" do
      supervisor = Fractor::Supervisor.new(
        worker_pools: [
          { worker_class: worker_class, num_workers: 2 },
        ],
        continuous_mode: true,
        debug: false,
      )

      # Add some work
      5.times { |i| supervisor.add_work_item(work_class.new(i + 1)) }

      # Start supervisor in a thread
      supervisor_thread = Thread.new do
        supervisor.run
      end

      # Wait a bit for work to be processed
      sleep(0.5)

      # Stop the supervisor
      supervisor.stop

      # Wait for thread to finish
      supervisor_thread.join(2)

      # Verify work was processed
      total_processed = supervisor.results.results.size + supervisor.results.errors.size
      expect(total_processed).to be > 0
    end
  end

  describe "shutdown with in-flight work" do
    it "handles shutdown when workers are processing" do
      slow_worker = Class.new(Fractor::Worker) do
        def process(work)
          sleep(0.1) # Simulate slow work
          value = work.input[:value]
          Fractor::WorkResult.new(result: value * 2, work: work)
        end
      end

      supervisor = Fractor::Supervisor.new(
        worker_pools: [
          { worker_class: slow_worker, num_workers: 2 },
        ],
        continuous_mode: true,
        debug: false,
      )

      # Add slow work
      10.times { |i| supervisor.add_work_item(work_class.new(i + 1)) }

      # Start supervisor in a thread
      supervisor_thread = Thread.new do
        supervisor.run
      end

      # Wait a bit then stop
      sleep(0.2)
      supervisor.stop

      # Wait for thread to finish with increased timeout for CI environments
      supervisor_thread.join(10)

      # Verify supervisor stopped cleanly (thread finished)
      expect(supervisor_thread.alive?).to be false
    end
  end

  describe "batch mode completion" do
    it "completes all work before exiting" do
      supervisor = Fractor::Supervisor.new(
        worker_pools: [
          { worker_class: worker_class, num_workers: 2 },
        ],
        debug: false,
      )

      # Add work
      work_items = Array.new(10) { |i| work_class.new(i + 1) }
      supervisor.add_work_items(work_items)

      # Run to completion
      Timeout.timeout(10) do
        supervisor.run
      end

      # Verify all work was processed
      total_processed = supervisor.results.results.size + supervisor.results.errors.size
      expect(total_processed).to eq(10)
    end

    it "returns correct results after completion" do
      supervisor = Fractor::Supervisor.new(
        worker_pools: [
          { worker_class: worker_class, num_workers: 2 },
        ],
        debug: false,
      )

      # Add work
      5.times { |i| supervisor.add_work_item(work_class.new(i + 1)) }

      # Run to completion
      Timeout.timeout(10) do
        supervisor.run
      end

      # Verify results (check both results and errors)
      total_processed = supervisor.results.results.size + supervisor.results.errors.size
      expect(total_processed).to eq(5)
      expect(supervisor.results.errors).to be_empty

      # Check values are doubled
      results = supervisor.results.results.map(&:result).sort
      expect(results).to eq([2, 4, 6, 8, 10])
    end
  end

  describe "error handling during shutdown" do
    it "handles worker shutdown gracefully" do
      # This test verifies that the supervisor doesn't crash
      # when starting and stopping workers

      supervisor = Fractor::Supervisor.new(
        worker_pools: [
          { worker_class: worker_class, num_workers: 2 },
        ],
        continuous_mode: true,
        debug: false,
      )

      # Start workers
      supervisor.start_workers
      expect(supervisor.workers.size).to eq(2)

      # Stop the supervisor
      expect { supervisor.stop }.not_to raise_error

      # Verify stop completed without hanging
      expect(supervisor.workers.size).to eq(2) # Workers still exist but are stopped
    end
  end

  describe "debug mode toggle" do
    it "can toggle debug mode" do
      supervisor = Fractor::Supervisor.new(
        worker_pools: [
          { worker_class: worker_class, num_workers: 2 },
        ],
      )

      # Default is false unless FRACTOR_DEBUG env var is set
      expect(supervisor.debug?).to be false

      # Enable debug mode
      supervisor.debug!
      expect(supervisor.debug?).to be true

      # Disable debug mode
      supervisor.debug_off!
      expect(supervisor.debug?).to be false
    end
  end

  describe "queue and worker inspection" do
    it "can inspect queue state" do
      supervisor = Fractor::Supervisor.new(
        worker_pools: [
          { worker_class: worker_class, num_workers: 2 },
        ],
      )

      # Queue is empty initially
      queue_info = supervisor.inspect_queue
      expect(queue_info[:size]).to eq(0)
      expect(queue_info[:total_added]).to eq(0)
      expect(queue_info[:items]).to be_empty

      # Add work items
      supervisor.add_work_items([
                                  work_class.new(1),
                                  work_class.new(2),
                                ])

      # Queue now has items
      queue_info = supervisor.inspect_queue
      expect(queue_info[:size]).to eq(2)
      expect(queue_info[:total_added]).to eq(2)
      expect(queue_info[:items].size).to eq(2)
    end

    it "can inspect worker status" do
      supervisor = Fractor::Supervisor.new(
        worker_pools: [
          { worker_class: worker_class, num_workers: 3 },
        ],
      )

      # Before starting workers
      status = supervisor.workers_status
      expect(status[:total]).to eq(0) # No workers started yet
      expect(status[:pools].size).to eq(1) # But pool config exists

      # After starting workers
      supervisor.start_workers
      status = supervisor.workers_status
      expect(status[:total]).to eq(3)
      expect(status[:pools].first[:workers].size).to eq(3)
    end
  end
end
