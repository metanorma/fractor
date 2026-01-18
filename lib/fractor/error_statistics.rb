# frozen_string_literal: true

module Fractor
  # Error statistics for a specific category or job.
  # Tracks error counts, severity distribution, and trends over time.
  class ErrorStatistics
    attr_reader :category, :total_count, :by_severity, :by_code, :recent_errors

    def initialize(category)
      @category = category
      @total_count = 0
      @by_severity = Hash.new(0)
      @by_code = Hash.new(0)
      @recent_errors = []
      @first_seen = nil
      @last_seen = nil
      @mutex = Mutex.new
    end

    # Record an error from a work result
    #
    # @param work_result [WorkResult] The failed work result
    # @return [void]
    def record(work_result)
      @mutex.synchronize do
        @total_count += 1
        @by_severity[work_result.error_severity] += 1
        @by_code[work_result.error_code] += 1 if work_result.error_code

        # Handle both String and Exception error types
        error_obj = work_result.error
        error_message = if error_obj.is_a?(Exception)
                          error_obj.message
                        elsif error_obj.is_a?(String)
                          error_obj
                        else
                          error_obj&.to_s
                        end

        error_entry = {
          timestamp: Time.now,
          error_class: error_obj.is_a?(Exception) ? error_obj.class.name : nil,
          error_message: error_message,
          error_code: work_result.error_code,
          error_severity: work_result.error_severity,
          error_context: work_result.error_context,
        }

        @recent_errors << error_entry
        @recent_errors.shift if @recent_errors.size > 100

        @first_seen ||= Time.now
        @last_seen = Time.now
      end
    end

    # Get error rate (errors per second)
    #
    # @return [Float] Errors per second
    def error_rate
      return 0.0 unless @first_seen && @last_seen

      duration = @last_seen - @first_seen
      return 0.0 if duration <= 0

      @total_count / duration
    end

    # Get most common error code
    #
    # @return [String, nil] Most common error code
    def most_common_code
      return nil if @by_code.empty?

      @by_code.max_by { |_code, count| count }&.first
    end

    # Get most severe error level
    #
    # @return [String, nil] Highest severity level
    def highest_severity
      return nil if @by_severity.empty?

      severities = [
        WorkResult::SEVERITY_CRITICAL,
        WorkResult::SEVERITY_ERROR,
        WorkResult::SEVERITY_WARNING,
        WorkResult::SEVERITY_INFO,
      ]

      severities.find { |severity| @by_severity[severity].positive? }
    end

    # Check if error rate is increasing
    #
    # @return [Boolean] True if errors are trending upward
    def increasing?
      return false if @recent_errors.size < 10

      recent_10 = @recent_errors.last(10)

      # Check if errors are happening in a short time span (rapid burst)
      first_timestamp = recent_10.first[:timestamp]
      last_timestamp = recent_10.last[:timestamp]
      total_timespan = last_timestamp - first_timestamp

      # If all errors happened in a very short time (burst), consider it increasing
      return true if total_timespan < 1.0 # Less than 1 second for 10 errors

      # Otherwise, check if the rate is increasing by comparing first half vs second half
      first_5 = recent_10.first(5)
      last_5 = recent_10.last(5)

      first_5_timespan = first_5.last[:timestamp] - first_5.first[:timestamp]
      last_5_timespan = last_5.last[:timestamp] - last_5.first[:timestamp]

      # Avoid division by zero - use small epsilon if timespan is very small
      first_5_timespan = 0.001 if first_5_timespan <= 0
      last_5_timespan = 0.001 if last_5_timespan <= 0

      # Calculate error rate (errors per second) for each group
      first_5_rate = 5.0 / first_5_timespan
      last_5_rate = 5.0 / last_5_timespan

      # Consider increasing if the rate is 50% higher
      last_5_rate > first_5_rate * 1.5
    end

    # Get summary hash
    #
    # @return [Hash] Summary of statistics
    def to_h
      {
        category: @category,
        total_count: @total_count,
        error_rate: error_rate.round(2),
        by_severity: @by_severity,
        by_code: @by_code,
        most_common_code: most_common_code,
        highest_severity: highest_severity,
        first_seen: @first_seen,
        last_seen: @last_seen,
        trending: increasing? ? "increasing" : "stable",
      }
    end
  end
end
