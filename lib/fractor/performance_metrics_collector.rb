# frozen_string_literal: true

module Fractor
  # Internal metrics collector for performance monitoring.
  # Thread-safe collection of performance metrics.
  class PerformanceMetricsCollector
    attr_reader :jobs_processed, :jobs_succeeded, :jobs_failed, :total_latency

    def initialize
      reset
    end

    # Reset all metrics to initial state
    def reset
      @jobs_processed = 0
      @jobs_succeeded = 0
      @jobs_failed = 0
      @latencies = []
      @total_latency = 0.0
      @queue_depths = []
      @memory_samples = []
      @utilization_samples = []
      @mutex = Mutex.new
    end

    # Record a job completion with its latency
    #
    # @param latency [Float] Job latency in seconds
    # @param success [Boolean] Whether job succeeded
    # @return [void]
    def record_job(latency, success: true)
      @mutex.synchronize do
        @jobs_processed += 1
        @jobs_succeeded += 1 if success
        @jobs_failed += 1 unless success
        @latencies << latency
        @total_latency += latency
      end
    end

    # Sample the current queue depth
    #
    # @param depth [Integer] Current queue depth
    # @return [void]
    def sample_queue_depth(depth)
      @mutex.synchronize do
        @queue_depths << depth
      end
    end

    # Sample current memory usage
    #
    # @param mb [Float] Memory usage in MB
    # @return [void]
    def sample_memory(mb)
      @mutex.synchronize do
        @memory_samples << mb
      end
    end

    # Sample worker utilization ratio
    #
    # @param ratio [Float] Worker utilization (0.0 to 1.0)
    # @return [void]
    def sample_worker_utilization(ratio)
      @mutex.synchronize do
        @utilization_samples << ratio
      end
    end

    # Calculate average latency
    #
    # @return [Float] Average latency in seconds
    def average_latency
      @mutex.synchronize do
        average_latency_unsynchronized
      end
    end

    # Calculate latency percentile
    #
    # @param p [Integer] Percentile (0-100)
    # @return [Float] Latency at percentile in seconds
    def percentile(p)
      @mutex.synchronize do
        return 0.0 if @latencies.empty?

        sorted = @latencies.sort
        index = ((p / 100.0) * sorted.size).ceil - 1
        sorted[[index, 0].max]
      end
    end

    # Calculate average queue depth
    #
    # @return [Float] Average queue depth
    def average_queue_depth
      @mutex.synchronize do
        return 0.0 if @queue_depths.empty?

        @queue_depths.sum / @queue_depths.size.to_f
      end
    end

    # Get maximum queue depth observed
    #
    # @return [Integer] Maximum queue depth
    def max_queue_depth
      @mutex.synchronize do
        return 0 if @queue_depths.empty?

        @queue_depths.max
      end
    end

    # Calculate enqueue rate (jobs per second)
    #
    # @param duration [Float] Time period in seconds
    # @return [Float] Enqueue rate
    def enqueue_rate(duration)
      return 0.0 if duration <= 0

      @jobs_processed / duration.to_f
    end

    # Calculate dequeue rate (jobs per second)
    #
    # @param duration [Float] Time period in seconds
    # @return [Float] Dequeue rate
    def dequeue_rate(duration)
      return 0.0 if duration <= 0

      @jobs_processed / duration.to_f
    end

    # Calculate average wait time using Little's Law
    #
    # @return [Float] Average wait time in seconds
    def average_wait_time
      # Wait time approximation based on queue depth and throughput
      @mutex.synchronize do
        return 0.0 if @queue_depths.empty? || @latencies.empty?

        avg_depth = @queue_depths.sum / @queue_depths.size.to_f
        avg_lat = @total_latency / @latencies.size
        return 0.0 if avg_lat.zero?

        # Little's Law: Wait Time ≈ Queue Length / Throughput
        avg_depth * avg_lat
      end
    end

    # Calculate wait time at a given percentile
    #
    # @param p [Integer] Percentile (0-100)
    # @return [Float] Wait time at percentile in seconds
    def wait_time_percentile(p)
      # Simplified wait time percentile based on queue depth percentile
      @mutex.synchronize do
        return 0.0 if @queue_depths.empty?

        sorted = @queue_depths.sort
        index = ((p / 100.0) * sorted.size).ceil - 1
        depth_percentile = sorted[[index, 0].max]

        avg_lat = @total_latency / @latencies.size
        return 0.0 if avg_lat.zero?

        depth_percentile * avg_lat
      end
    end

    private

    def average_latency_unsynchronized
      return 0.0 if @latencies.empty?

      @total_latency / @latencies.size
    end
  end
end
