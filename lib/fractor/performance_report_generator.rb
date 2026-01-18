# frozen_string_literal: true

require "json"

module Fractor
  # Generates formatted reports from performance metrics snapshots.
  # Supports text, JSON, and Prometheus output formats.
  class PerformanceReportGenerator
    # Generate a human-readable text report
    #
    # @param stats [Hash] Metrics snapshot from PerformanceMonitor
    # @return [String] Formatted report
    def self.generate_report(stats)
      <<~REPORT
        Performance Metrics
        ===================
        Duration: #{format_duration(stats[:uptime])}

        Jobs:
          Processed: #{stats[:jobs_processed]}
          Succeeded: #{stats[:jobs_succeeded]}
          Failed: #{stats[:jobs_failed]}
          Success Rate: #{success_rate(stats)}%

        Latency (ms):
          Average: #{format_ms(stats[:average_latency])}
          P50: #{format_ms(stats[:p50_latency])}
          P95: #{format_ms(stats[:p95_latency])}
          P99: #{format_ms(stats[:p99_latency])}

        Throughput:
          Jobs/sec: #{format_float(stats[:throughput])}

        Workers:
          Total: #{stats[:worker_count]}
          Active: #{stats[:active_workers]}
          Utilization: #{format_percent(stats[:worker_utilization])}

        Queue:
          Current Depth: #{stats[:queue_depth]}
          Average Depth: #{format_float(stats[:queue_depth_avg])}
          Max Depth: #{stats[:queue_depth_max]}
          Enqueue Rate: #{format_float(stats[:enqueue_rate])} items/sec
          Dequeue Rate: #{format_float(stats[:dequeue_rate])} items/sec

        Wait Time (ms):
          Average: #{format_ms(stats[:average_wait_time])}
          P50: #{format_ms(stats[:p50_wait_time])}
          P95: #{format_ms(stats[:p95_wait_time])}
          P99: #{format_ms(stats[:p99_wait_time])}

        Memory:
          Current: #{format_float(stats[:memory_mb])} MB
      REPORT
    end

    # Export metrics in JSON format
    #
    # @param stats [Hash] Metrics snapshot
    # @return [String] JSON representation
    def self.to_json(stats)
      stats.to_json
    end

    # Export metrics in Prometheus format
    #
    # @param stats [Hash] Metrics snapshot
    # @param total_latency [Float] Total latency for all jobs
    # @param prefix [String] Metric name prefix
    # @return [String] Prometheus metrics
    def self.to_prometheus(stats, total_latency, prefix: "fractor")
      <<~PROMETHEUS
        # HELP #{prefix}_jobs_processed_total Total number of jobs processed
        # TYPE #{prefix}_jobs_processed_total counter
        #{prefix}_jobs_processed_total #{stats[:jobs_processed]}

        # HELP #{prefix}_jobs_succeeded_total Total number of jobs that succeeded
        # TYPE #{prefix}_jobs_succeeded_total counter
        #{prefix}_jobs_succeeded_total #{stats[:jobs_succeeded]}

        # HELP #{prefix}_jobs_failed_total Total number of jobs that failed
        # TYPE #{prefix}_jobs_failed_total counter
        #{prefix}_jobs_failed_total #{stats[:jobs_failed]}

        # HELP #{prefix}_latency_seconds Job processing latency
        # TYPE #{prefix}_latency_seconds summary
        #{prefix}_latency_seconds{quantile="0.5"} #{stats[:p50_latency] || 0}
        #{prefix}_latency_seconds{quantile="0.95"} #{stats[:p95_latency] || 0}
        #{prefix}_latency_seconds{quantile="0.99"} #{stats[:p99_latency] || 0}
        #{prefix}_latency_seconds_sum #{total_latency}
        #{prefix}_latency_seconds_count #{stats[:jobs_processed]}

        # HELP #{prefix}_throughput_jobs_per_second Current throughput
        # TYPE #{prefix}_throughput_jobs_per_second gauge
        #{prefix}_throughput_jobs_per_second #{stats[:throughput] || 0}

        # HELP #{prefix}_queue_depth Current queue depth
        # TYPE #{prefix}_queue_depth gauge
        #{prefix}_queue_depth #{stats[:queue_depth]}

        # HELP #{prefix}_queue_depth_avg Average queue depth
        # TYPE #{prefix}_queue_depth_avg gauge
        #{prefix}_queue_depth_avg #{stats[:queue_depth_avg] || 0}

        # HELP #{prefix}_queue_depth_max Maximum queue depth
        # TYPE #{prefix}_queue_depth_max gauge
        #{prefix}_queue_depth_max #{stats[:queue_depth_max] || 0}

        # HELP #{prefix}_enqueue_rate_total Items enqueued per second
        # TYPE #{prefix}_enqueue_rate_total gauge
        #{prefix}_enqueue_rate_total #{stats[:enqueue_rate] || 0}

        # HELP #{prefix}_dequeue_rate_total Items dequeued per second
        # TYPE #{prefix}_dequeue_rate_total gauge
        #{prefix}_dequeue_rate_total #{stats[:dequeue_rate] || 0}

        # HELP #{prefix}_wait_time_seconds Queue wait time
        # TYPE #{prefix}_wait_time_seconds summary
        #{prefix}_wait_time_seconds{quantile="0.5"} #{stats[:p50_wait_time] || 0}
        #{prefix}_wait_time_seconds{quantile="0.95"} #{stats[:p95_wait_time] || 0}
        #{prefix}_wait_time_seconds{quantile="0.99"} #{stats[:p99_wait_time] || 0}
        #{prefix}_wait_time_seconds_sum #{stats[:average_wait_time] || 0}
        #{prefix}_wait_time_seconds_count #{stats[:jobs_processed]}

        # HELP #{prefix}_workers_total Total number of workers
        # TYPE #{prefix}_workers_total gauge
        #{prefix}_workers_total #{stats[:worker_count]}

        # HELP #{prefix}_workers_active Number of active workers
        # TYPE #{prefix}_workers_active gauge
        #{prefix}_workers_active #{stats[:active_workers]}

        # HELP #{prefix}_worker_utilization Worker utilization ratio
        # TYPE #{prefix}_worker_utilization gauge
        #{prefix}_worker_utilization #{stats[:worker_utilization] || 0}

        # HELP #{prefix}_memory_bytes Current memory usage
        # TYPE #{prefix}_memory_bytes gauge
        #{prefix}_memory_bytes #{(stats[:memory_mb] || 0) * 1024 * 1024}
      PROMETHEUS
    end

    # Calculate success rate from metrics
    #
    # @param stats [Hash] Metrics snapshot
    # @return [Float] Success rate percentage
    def self.success_rate(stats)
      total = stats[:jobs_processed]
      return 0.0 if total.zero?

      (stats[:jobs_succeeded].to_f / total * 100).round(2)
    end

    # Format duration in human-readable format
    #
    # @param seconds [Float] Duration in seconds
    # @return [String] Formatted duration (e.g., "1h 30m 45s")
    def self.format_duration(seconds)
      return "0s" if seconds.nil? || seconds.zero?

      hours = (seconds / 3600).floor
      minutes = ((seconds % 3600) / 60).floor
      secs = (seconds % 60).round(2)

      parts = []
      parts << "#{hours}h" if hours.positive?
      parts << "#{minutes}m" if minutes.positive?
      parts << "#{secs}s"
      parts.join(" ")
    end

    # Format seconds as milliseconds
    #
    # @param seconds [Float] Duration in seconds
    # @return [String] Milliseconds with 2 decimal places
    def self.format_ms(seconds)
      return "0.00" if seconds.nil?

      (seconds * 1000).round(2)
    end

    # Format float value with 2 decimal places
    #
    # @param value [Float] Value to format
    # @return [String] Formatted float
    def self.format_float(value)
      return "0.00" if value.nil?

      value.round(2)
    end

    # Format ratio as percentage
    #
    # @param ratio [Float] Ratio (0.0 to 1.0)
    # @return [String] Percentage with 2 decimal places
    def self.format_percent(ratio)
      return "0.00%" if ratio.nil?

      "#{(ratio * 100).round(2)}%"
    end
  end
end
