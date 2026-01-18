# frozen_string_literal: true

require "spec_helper"
require_relative "../../lib/fractor/performance_monitor"

# Simple test worker for performance monitoring tests
class SimpleWorker < Fractor::Worker
  def process(work)
    value = work.input[:value] || work.input[:data] || 0
    Fractor::WorkResult.new(result: value, work: work)
  end
end

RSpec.describe Fractor::PerformanceMonitor do
  let(:supervisor) do
    Fractor::Supervisor.new(
      worker_pools: [
        { worker_class: SimpleWorker, num_workers: 4 },
      ],
    )
  end
  let(:monitor) { described_class.new(supervisor) }

  describe "#initialize" do
    it "creates a monitor with default sample interval" do
      expect(monitor.supervisor).to eq(supervisor)
      expect(monitor).not_to be_monitoring
    end

    it "accepts custom sample interval" do
      custom_monitor = described_class.new(supervisor, sample_interval: 0.5)
      expect(custom_monitor.instance_variable_get(:@sample_interval)).to eq(0.5)
    end
  end

  describe "#start and #stop" do
    it "starts monitoring" do
      monitor.start
      expect(monitor).to be_monitoring
      expect(monitor.start_time).not_to be_nil
      monitor.stop
    end

    it "stops monitoring" do
      monitor.start
      monitor.stop
      expect(monitor).not_to be_monitoring
      expect(monitor.end_time).not_to be_nil
    end

    it "does not start twice" do
      monitor.start
      start_time1 = monitor.start_time

      sleep 0.01
      monitor.start
      start_time2 = monitor.start_time

      expect(start_time1).to eq(start_time2)
      monitor.stop
    end

    it "does not stop twice" do
      monitor.start
      monitor.stop
      end_time1 = monitor.end_time

      sleep 0.01
      monitor.stop
      end_time2 = monitor.end_time

      expect(end_time1).to eq(end_time2)
    end
  end

  describe "#record_job" do
    it "records successful job" do
      monitor.record_job(0.1, success: true)

      snapshot = monitor.snapshot
      expect(snapshot[:jobs_processed]).to eq(1)
      expect(snapshot[:jobs_succeeded]).to eq(1)
      expect(snapshot[:jobs_failed]).to eq(0)
    end

    it "records failed job" do
      monitor.record_job(0.2, success: false)

      snapshot = monitor.snapshot
      expect(snapshot[:jobs_processed]).to eq(1)
      expect(snapshot[:jobs_succeeded]).to eq(0)
      expect(snapshot[:jobs_failed]).to eq(1)
    end

    it "tracks latency" do
      monitor.record_job(0.1)
      monitor.record_job(0.2)
      monitor.record_job(0.3)

      snapshot = monitor.snapshot
      expect(snapshot[:average_latency]).to be_within(0.01).of(0.2)
    end
  end

  describe "#snapshot" do
    before do
      monitor.start
      monitor.record_job(0.1)
      monitor.record_job(0.2)
      monitor.record_job(0.3)
    end

    after do
      monitor.stop
    end

    it "returns current metrics" do
      snapshot = monitor.snapshot

      expect(snapshot).to include(
        jobs_processed: 3,
        jobs_succeeded: 3,
        jobs_failed: 0,
      )

      expect(snapshot[:average_latency]).to be_within(0.01).of(0.2)
      expect(snapshot[:throughput]).to be > 0
      expect(snapshot[:uptime]).to be > 0
    end

    it "calculates percentiles" do
      # Add more samples for better percentile calculation
      10.times { |i| monitor.record_job(i * 0.01) }

      snapshot = monitor.snapshot
      expect(snapshot[:p50_latency]).to be_a(Float)
      expect(snapshot[:p95_latency]).to be_a(Float)
      expect(snapshot[:p99_latency]).to be_a(Float)
      expect(snapshot[:p95_latency]).to be >= snapshot[:p50_latency]
      expect(snapshot[:p99_latency]).to be >= snapshot[:p95_latency]
    end
  end

  describe "#report" do
    before do
      monitor.start
      monitor.record_job(0.05)
      monitor.record_job(0.10)
      monitor.record_job(0.15)
    end

    after do
      monitor.stop
    end

    it "generates human-readable report" do
      report = monitor.report

      expect(report).to include("Performance Metrics")
      expect(report).to include("Jobs:")
      expect(report).to include("Latency (ms):")
      expect(report).to include("Throughput:")
      expect(report).to include("Workers:")
      expect(report).to include("Processed: 3")
    end

    it "includes success rate" do
      monitor.record_job(0.1, success: false)
      report = monitor.report

      expect(report).to include("Success Rate:")
    end
  end

  describe "#to_json" do
    before do
      monitor.record_job(0.1)
    end

    it "exports metrics as JSON" do
      json_str = monitor.to_json
      data = JSON.parse(json_str)

      expect(data).to include(
        "jobs_processed" => 1,
        "jobs_succeeded" => 1,
        "jobs_failed" => 0,
      )
    end
  end

  describe "#to_prometheus" do
    before do
      monitor.start
      monitor.record_job(0.1)
      monitor.record_job(0.2)
    end

    after do
      monitor.stop
    end

    it "exports metrics in Prometheus format" do
      prometheus = monitor.to_prometheus

      expect(prometheus).to include("fractor_jobs_processed_total 2")
      expect(prometheus).to include("fractor_jobs_succeeded_total 2")
      expect(prometheus).to include("fractor_jobs_failed_total 0")
      expect(prometheus).to include("# TYPE fractor_jobs_processed_total counter")
      expect(prometheus).to include("# TYPE fractor_latency_seconds summary")
    end

    it "includes quantiles" do
      prometheus = monitor.to_prometheus

      expect(prometheus).to include('quantile="0.5"')
      expect(prometheus).to include('quantile="0.95"')
      expect(prometheus).to include('quantile="0.99"')
    end

    it "includes worker metrics" do
      prometheus = monitor.to_prometheus

      expect(prometheus).to include("fractor_workers_total")
      expect(prometheus).to include("fractor_workers_active")
      expect(prometheus).to include("fractor_worker_utilization")
    end
  end

  describe "MetricsCollector" do
    let(:collector) { Fractor::PerformanceMetricsCollector.new }

    describe "#record_job" do
      it "increments counters" do
        collector.record_job(0.1, success: true)
        collector.record_job(0.2, success: false)

        expect(collector.jobs_processed).to eq(2)
        expect(collector.jobs_succeeded).to eq(1)
        expect(collector.jobs_failed).to eq(1)
      end

      it "tracks total latency" do
        collector.record_job(0.1)
        collector.record_job(0.2)

        expect(collector.total_latency).to be_within(0.01).of(0.3)
      end
    end

    describe "#average_latency" do
      it "calculates average" do
        collector.record_job(0.1)
        collector.record_job(0.2)
        collector.record_job(0.3)

        expect(collector.average_latency).to be_within(0.01).of(0.2)
      end

      it "returns 0 for no jobs" do
        expect(collector.average_latency).to eq(0.0)
      end
    end

    describe "#percentile" do
      before do
        [0.1, 0.2, 0.3, 0.4, 0.5].each do |latency|
          collector.record_job(latency)
        end
      end

      it "calculates p50" do
        expect(collector.percentile(50)).to be_within(0.05).of(0.3)
      end

      it "calculates p95" do
        p95 = collector.percentile(95)
        expect(p95).to be >= 0.4
      end

      it "calculates p99" do
        p99 = collector.percentile(99)
        expect(p99).to be >= collector.percentile(95)
      end

      it "returns 0 for no jobs" do
        empty_collector = Fractor::PerformanceMetricsCollector.new
        expect(empty_collector.percentile(50)).to eq(0.0)
      end
    end

    describe "#reset" do
      it "clears all metrics" do
        collector.record_job(0.1)
        collector.record_job(0.2)

        collector.reset

        expect(collector.jobs_processed).to eq(0)
        expect(collector.jobs_succeeded).to eq(0)
        expect(collector.jobs_failed).to eq(0)
        expect(collector.total_latency).to eq(0.0)
      end
    end

    describe "thread safety" do
      it "handles concurrent updates" do
        threads = Array.new(10) do
          Thread.new do
            100.times { collector.record_job(0.01) }
          end
        end

        threads.each(&:join)

        expect(collector.jobs_processed).to eq(1000)
        expect(collector.jobs_succeeded).to eq(1000)
      end
    end
  end

  describe "throughput calculation" do
    it "calculates jobs per second" do
      monitor.start
      sleep 0.1

      10.times { monitor.record_job(0.01) }
      sleep 0.1

      snapshot = monitor.snapshot
      expect(snapshot[:throughput]).to be > 0
      expect(snapshot[:throughput]).to be < 1000 # Sanity check

      monitor.stop
    end

    it "returns 0 before starting" do
      snapshot = monitor.snapshot
      expect(snapshot[:throughput]).to eq(0.0)
    end
  end

  describe "queue depth tracking" do
    it "tracks current queue depth" do
      5.times { supervisor.work_queue.push(Fractor::Work.new({ value: 1 })) }

      snapshot = monitor.snapshot
      expect(snapshot[:queue_depth]).to eq(5)
    end

    it "returns 0 for empty queue" do
      snapshot = monitor.snapshot
      expect(snapshot[:queue_depth]).to eq(0)
    end
  end

  describe "worker metrics" do
    it "counts total workers" do
      snapshot = monitor.snapshot
      expect(snapshot[:worker_count]).to eq(4)
    end

    it "estimates worker utilization" do
      # With empty queue, utilization should be low
      snapshot = monitor.snapshot
      expect(snapshot[:worker_utilization]).to be >= 0.0
      expect(snapshot[:worker_utilization]).to be <= 1.0
    end
  end

  describe "memory tracking" do
    it "tracks memory usage" do
      snapshot = monitor.snapshot
      # Memory should be positive on supported platforms
      expect(snapshot[:memory_mb]).to be >= 0.0
    end
  end

  describe "uptime calculation" do
    it "calculates uptime while running" do
      monitor.start
      sleep 0.1

      snapshot = monitor.snapshot
      expect(snapshot[:uptime]).to be >= 0.1
      expect(snapshot[:uptime]).to be < 1.0

      monitor.stop
    end

    it "freezes uptime after stopping" do
      monitor.start
      sleep 0.05
      monitor.stop

      uptime1 = monitor.snapshot[:uptime]
      sleep 0.05
      uptime2 = monitor.snapshot[:uptime]

      expect(uptime1).to eq(uptime2)
    end
  end
end
