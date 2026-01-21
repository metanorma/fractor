# frozen_string_literal: true

require "fractor/performance_monitor"
require "json"

RSpec.describe "Performance Monitoring Example" do
  # Worker from the example
  class VariableLatencyWorker < Fractor::Worker
    def process(work)
      # Simulate variable work latency
      sleep(rand * 0.01) # Reduced for testing

      result = work.input[:value] * 2
      Fractor::WorkResult.new(result: result, work: work)
    end
  end

  let(:supervisor) do
    Fractor::Supervisor.new(
      worker_pools: [
        { worker_class: VariableLatencyWorker, num_workers: 2 },
      ],
    )
  end

  let(:monitor) { Fractor::PerformanceMonitor.new(supervisor, sample_interval: 0.1) }

  describe "VariableLatencyWorker" do
    it "processes work by doubling the value" do
      work = Fractor::Work.new({ value: 5 })
      result = VariableLatencyWorker.new.process(work)

      expect(result).to be_success
      expect(result.result).to eq(10)
    end

    it "returns a WorkResult with the correct structure" do
      work = Fractor::Work.new({ value: 21 })
      result = VariableLatencyWorker.new.process(work)

      expect(result.work).to eq(work)
      expect(result.success?).to be true
    end
  end

  describe "PerformanceMonitor" do
    describe "initialization" do
      it "creates a monitor with a supervisor" do
        expect(monitor.supervisor).to eq(supervisor)
      end

      it "has a configurable sample interval" do
        custom_monitor = Fractor::PerformanceMonitor.new(supervisor,
                                                         sample_interval: 0.5)

        expect(custom_monitor).to be_a(Fractor::PerformanceMonitor)
      end

      it "starts in a stopped state" do
        expect(monitor.monitoring?).to be false
      end
    end

    describe "monitoring lifecycle" do
      it "starts monitoring when start is called" do
        monitor.start
        expect(monitor.monitoring?).to be true
        monitor.stop
      end

      it "stops monitoring when stop is called" do
        monitor.start
        monitor.stop
        expect(monitor.monitoring?).to be false
      end

      it "records start and end times" do
        monitor.start
        sleep 0.05
        monitor.stop

        expect(monitor.start_time).to be_a(Time)
        expect(monitor.end_time).to be_a(Time)
        expect(monitor.end_time).to be > monitor.start_time
      end
    end

    describe "metrics snapshot" do
      before do
        monitor.start
        # Manually record some jobs
        monitor.record_job(0.01, success: true)
        monitor.record_job(0.02, success: true)
        monitor.record_job(0.03, success: false)
        monitor.stop
      end

      it "tracks jobs processed" do
        snapshot = monitor.snapshot
        expect(snapshot[:jobs_processed]).to eq(3)
      end

      it "tracks succeeded and failed jobs separately" do
        snapshot = monitor.snapshot
        expect(snapshot[:jobs_succeeded]).to eq(2)
        expect(snapshot[:jobs_failed]).to eq(1)
      end

      it "calculates average latency" do
        snapshot = monitor.snapshot
        # (0.01 + 0.02 + 0.03) / 3 = 0.02
        expect(snapshot[:average_latency]).to be_within(0.001).of(0.02)
      end

      it "includes execution time" do
        snapshot = monitor.snapshot
        expect(snapshot[:uptime]).to be_a(Float)
        expect(snapshot[:uptime]).to be >= 0
      end
    end

    describe "latency percentiles" do
      before do
        monitor.start
        # Record jobs with known latencies
        [0.01, 0.02, 0.03, 0.04, 0.05, 0.06, 0.07, 0.08, 0.09,
         0.10].each do |latency|
          monitor.record_job(latency, success: true)
        end
        monitor.stop
      end

      it "calculates p50 latency" do
        snapshot = monitor.snapshot
        expect(snapshot[:p50_latency]).to be_a(Float)
        expect(snapshot[:p50_latency]).to be > 0
      end

      it "calculates p95 latency" do
        snapshot = monitor.snapshot
        expect(snapshot[:p95_latency]).to be_a(Float)
        expect(snapshot[:p95_latency]).to be > 0
      end

      it "calculates p99 latency" do
        snapshot = monitor.snapshot
        expect(snapshot[:p99_latency]).to be_a(Float)
        expect(snapshot[:p99_latency]).to be > 0
      end
    end

    describe "throughput calculation" do
      it "calculates jobs per second" do
        monitor.start
        5.times { monitor.record_job(0.01, success: true) }
        sleep 0.05 # Let some time pass
        monitor.stop

        snapshot = monitor.snapshot
        expect(snapshot[:throughput]).to be_a(Float)
        expect(snapshot[:throughput]).to be > 0
      end
    end

    describe "queue metrics" do
      it "tracks current queue depth" do
        snapshot = monitor.snapshot
        expect(snapshot[:queue_depth]).to be_a(Integer)
      end

      it "tracks average queue depth" do
        snapshot = monitor.snapshot
        expect(snapshot[:queue_depth_avg]).to be_a(Float)
      end

      it "tracks max queue depth" do
        snapshot = monitor.snapshot
        expect(snapshot[:queue_depth_max]).to be_a(Integer)
      end
    end

    describe "worker metrics" do
      it "tracks total worker count" do
        snapshot = monitor.snapshot
        expect(snapshot[:worker_count]).to eq(2)
      end

      it "tracks active worker count" do
        snapshot = monitor.snapshot
        expect(snapshot[:active_workers]).to be_a(Integer)
      end

      it "calculates worker utilization" do
        snapshot = monitor.snapshot
        expect(snapshot[:worker_utilization]).to be_a(Float)
        expect(snapshot[:worker_utilization]).to be >= 0.0
        expect(snapshot[:worker_utilization]).to be <= 1.0
      end
    end

    describe "report generation" do
      before do
        monitor.start
        monitor.record_job(0.01, success: true)
        monitor.record_job(0.02, success: false)
        monitor.stop
      end

      it "generates a human-readable report" do
        report = monitor.report

        expect(report).to be_a(String)
        expect(report).to include("Performance Metrics")
        expect(report).to include("Jobs:")
        expect(report).to include("Processed:")
        expect(report).to include("Succeeded:")
        expect(report).to include("Failed:")
      end

      it "exports to JSON" do
        json = monitor.to_json

        expect(json).to be_a(String)
        parsed = JSON.parse(json)
        expect(parsed["jobs_processed"]).to eq(2)
      end

      it "exports to Prometheus format" do
        prometheus = monitor.to_prometheus

        expect(prometheus).to be_a(String)
        expect(prometheus).to include("# HELP")
        expect(prometheus).to include("# TYPE")
        expect(prometheus).to include("fractor_jobs_processed_total")
        expect(prometheus).to include("fractor_jobs_succeeded_total")
        expect(prometheus).to include("fractor_jobs_failed_total")
        expect(prometheus).to include("fractor_latency_seconds")
        expect(prometheus).to include("fractor_workers_total")
      end
    end

    describe "manual job recording" do
      it "allows manual recording of job completions" do
        monitor.start
        monitor.record_job(0.015, success: true)
        monitor.record_job(0.025, success: false)
        monitor.stop

        snapshot = monitor.snapshot
        expect(snapshot[:jobs_processed]).to eq(2)
        expect(snapshot[:jobs_succeeded]).to eq(1)
        expect(snapshot[:jobs_failed]).to eq(1)
      end

      it "tracks latency manually recorded jobs" do
        monitor.start
        monitor.record_job(0.01, success: true)
        monitor.record_job(0.02, success: true)
        monitor.record_job(0.03, success: true)
        monitor.stop

        snapshot = monitor.snapshot
        expect(snapshot[:average_latency]).to be_within(0.001).of(0.02)
      end
    end

    describe "integration with supervisor" do
      it "monitors work processed by supervisor" do
        # Add work to supervisor
        5.times do |i|
          supervisor.add_work_item(Fractor::Work.new({ value: i }))
        end

        # Start monitor and supervisor
        monitor.start
        supervisor_thread = Thread.new { supervisor.run }

        # Wait for completion
        sleep 0.5 while !supervisor.work_queue.empty?

        monitor.stop
        supervisor.stop
        supervisor_thread.join

        # Check that work was processed
        expect(supervisor.results.results.size).to eq(5)
        expect(supervisor.results.results.all?(&:success?)).to be true
      end

      it "tracks metrics from supervisor execution" do
        monitor.start
        3.times do |i|
          supervisor.add_work_item(Fractor::Work.new({ value: i }))
        end

        supervisor_thread = Thread.new { supervisor.run }
        sleep 0.5 while !supervisor.work_queue.empty?

        # Manually record completed jobs
        supervisor.results.results.each do |result|
          monitor.record_job(0.01, success: result.success?)
        end

        monitor.stop
        supervisor.stop
        supervisor_thread.join

        snapshot = monitor.snapshot
        expect(snapshot[:jobs_processed]).to eq(3)
      end
    end
  end

  describe "PerformanceMonitor reset functionality" do
    it "resets metrics when monitor is restarted" do
      monitor.start
      monitor.record_job(0.01, success: true)
      monitor.stop

      expect(monitor.snapshot[:jobs_processed]).to eq(1)

      # Restart
      monitor.start
      monitor.record_job(0.01, success: true)
      monitor.stop

      expect(monitor.snapshot[:jobs_processed]).to eq(1) # Reset on start
    end
  end

  describe "wait time metrics" do
    it "tracks average wait time" do
      monitor.start
      monitor.record_job(0.01, success: true)
      monitor.stop

      snapshot = monitor.snapshot
      expect(snapshot[:average_wait_time]).to be_a(Float)
    end

    it "tracks wait time percentiles" do
      monitor.start
      5.times { monitor.record_job(0.01, success: true) }
      monitor.stop

      snapshot = monitor.snapshot
      expect(snapshot[:p50_wait_time]).to be_a(Float)
      expect(snapshot[:p95_wait_time]).to be_a(Float)
      expect(snapshot[:p99_wait_time]).to be_a(Float)
    end
  end

  describe "memory tracking" do
    it "tracks memory usage in MB" do
      monitor.start
      monitor.record_job(0.01, success: true)
      monitor.stop

      snapshot = monitor.snapshot
      expect(snapshot[:memory_mb]).to be_a(Float)
      expect(snapshot[:memory_mb]).to be >= 0
    end
  end

  describe "enqueue/dequeue rates" do
    it "calculates enqueue rate" do
      monitor.start
      5.times { monitor.record_job(0.01, success: true) }
      monitor.stop

      snapshot = monitor.snapshot
      expect(snapshot[:enqueue_rate]).to be_a(Float)
    end

    it "calculates dequeue rate" do
      monitor.start
      5.times { monitor.record_job(0.01, success: true) }
      monitor.stop

      snapshot = monitor.snapshot
      expect(snapshot[:dequeue_rate]).to be_a(Float)
    end
  end
end
