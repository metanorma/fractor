# frozen_string_literal: true

require_relative "performance_metrics_collector"
require_relative "performance_report_generator"

module Fractor
  # Monitors and tracks performance metrics for Fractor supervisors and workers.
  #
  # Collects metrics including:
  # - Jobs processed count
  # - Latency statistics (average, p50, p95, p99)
  # - Throughput (jobs/second)
  # - Worker utilization
  # - Queue depth over time
  # - Memory usage
  #
  # @example Basic usage
  #   supervisor = Fractor::Supervisor.new(...)
  #   monitor = Fractor::PerformanceMonitor.new(supervisor)
  #   monitor.start
  #
  #   # ... run workload ...
  #
  #   monitor.stop
  #   puts monitor.report
  #
  # @example With custom sampling interval
  #   monitor = Fractor::PerformanceMonitor.new(
  #     supervisor,
  #     sample_interval: 0.5  # Sample every 500ms
  #   )
  class PerformanceMonitor
    attr_reader :supervisor, :metrics, :start_time, :end_time

    # Create a new performance monitor
    #
    # @param supervisor [Supervisor] The supervisor to monitor
    # @param sample_interval [Float] How often to sample metrics (seconds)
    def initialize(supervisor, sample_interval: 1.0)
      @supervisor = supervisor
      @sample_interval = sample_interval
      @metrics = PerformanceMetricsCollector.new
      @start_time = nil
      @end_time = nil
      @monitoring = false
      @monitor_thread = nil
    end

    # Start monitoring
    #
    # @return [void]
    def start
      return if @monitoring

      @monitoring = true
      @start_time = Time.now
      @metrics.reset

      # Start background monitoring thread
      @monitor_thread = Thread.new { monitor_loop }
    end

    # Stop monitoring
    #
    # @return [void]
    def stop
      return unless @monitoring

      @monitoring = false
      @end_time = Time.now
      @monitor_thread&.join
      @monitor_thread = nil
    end

    # Check if currently monitoring
    #
    # @return [Boolean]
    def monitoring?
      @monitoring
    end

    # Get current metrics snapshot
    #
    # @return [Hash] Current metrics
    def snapshot
      {
        jobs_processed: @metrics.jobs_processed,
        jobs_succeeded: @metrics.jobs_succeeded,
        jobs_failed: @metrics.jobs_failed,
        average_latency: @metrics.average_latency,
        p50_latency: @metrics.percentile(50),
        p95_latency: @metrics.percentile(95),
        p99_latency: @metrics.percentile(99),
        throughput: calculate_throughput,
        queue_depth: current_queue_depth,
        queue_depth_avg: @metrics.average_queue_depth,
        queue_depth_max: @metrics.max_queue_depth,
        enqueue_rate: @metrics.enqueue_rate(uptime),
        dequeue_rate: @metrics.dequeue_rate(uptime),
        average_wait_time: @metrics.average_wait_time,
        p50_wait_time: @metrics.wait_time_percentile(50),
        p95_wait_time: @metrics.wait_time_percentile(95),
        p99_wait_time: @metrics.wait_time_percentile(99),
        worker_count: worker_count,
        active_workers: active_worker_count,
        worker_utilization: worker_utilization,
        memory_mb: current_memory_mb,
        uptime: uptime,
      }
    end

    # Generate a human-readable report
    #
    # @return [String] Formatted report
    def report
      PerformanceReportGenerator.generate_report(snapshot)
    end

    # Export metrics in JSON format
    #
    # @return [String] JSON representation
    def to_json(*_args)
      PerformanceReportGenerator.to_json(snapshot)
    end

    # Export metrics in Prometheus format
    #
    # @return [String] Prometheus metrics
    def to_prometheus
      stats = snapshot
      PerformanceReportGenerator.to_prometheus(stats, @metrics.total_latency)
    end

    # Record a job completion
    #
    # @param latency [Float] Job latency in seconds
    # @param success [Boolean] Whether job succeeded
    # @return [void]
    def record_job(latency, success: true)
      @metrics.record_job(latency, success: success)
    end

    private

    def monitor_loop
      while @monitoring
        sample_metrics
        sleep(@sample_interval)
      end
    rescue StandardError => e
      warn "Performance monitor error: #{e.message}"
    end

    def sample_metrics
      @metrics.sample_queue_depth(current_queue_depth)
      @metrics.sample_memory(current_memory_mb)
      @metrics.sample_worker_utilization(worker_utilization)
    end

    def calculate_throughput
      duration = uptime
      return 0.0 if duration <= 0

      @metrics.jobs_processed / duration.to_f
    end

    def uptime
      end_time = @end_time || Time.now
      return 0 unless @start_time

      end_time - @start_time
    end

    def current_queue_depth
      @supervisor.work_queue.size
    rescue StandardError
      0
    end

    def worker_count
      @supervisor.worker_pools.sum { |pool| pool[:num_workers] || 1 }
    rescue StandardError
      0
    end

    def active_worker_count
      # This would need worker state tracking
      # For now, estimate based on queue depth
      depth = current_queue_depth
      total = worker_count
      return total if depth.positive?

      0
    end

    def worker_utilization
      total = worker_count
      return 0.0 if total.zero?

      active = active_worker_count
      active.to_f / total
    end

    def current_memory_mb
      # Get current process memory usage in MB
      if RUBY_PLATFORM.match?(/darwin|linux/)
        `ps -o rss= -p #{Process.pid}`.to_i / 1024.0
      else
        0.0 # Unsupported platform
      end
    rescue StandardError
      0.0
    end
  end
end
