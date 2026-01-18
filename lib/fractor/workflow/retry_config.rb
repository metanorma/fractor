# frozen_string_literal: true

require_relative "retry_strategy"

module Fractor
  class Workflow
    # Configuration for job retry behavior
    class RetryConfig
      attr_reader :strategy, :timeout, :retryable_errors

      def initialize(
        strategy: NoRetry.new,
        timeout: nil,
        retryable_errors: [StandardError]
      )
        @strategy = strategy
        @timeout = timeout
        @retryable_errors = Array(retryable_errors)
      end

      # Check if an error should trigger a retry
      # @param error [Exception] The error to check
      # @return [Boolean] true if error should be retried
      def retryable?(error)
        retryable_errors.any? { |err_class| error.is_a?(err_class) }
      end

      # Get maximum number of retry attempts
      # @return [Integer] Maximum attempts
      def max_attempts
        strategy.max_attempts
      end

      # Calculate delay for a given attempt
      # @param attempt [Integer] The attempt number
      # @return [Numeric] Delay in seconds
      def delay_for(attempt)
        strategy.delay_for(attempt)
      end

      # Create a retry config from a hash of options
      # @param options [Hash] Configuration options
      # @option options [Symbol] :backoff Strategy type (:exponential, :linear, :constant, :none)
      # @option options [Integer] :max_attempts Maximum retry attempts
      # @option options [Numeric] :initial_delay Initial delay in seconds
      # @option options [Numeric] :max_delay Maximum delay in seconds
      # @option options [Numeric] :timeout Job timeout in seconds
      # @option options [Array<Class>] :retryable_errors List of retryable error classes
      # @return [RetryConfig] New retry configuration
      def self.from_options(**options)
        strategy = create_strategy(**options)
        new(
          strategy: strategy,
          timeout: options[:timeout],
          retryable_errors: options[:retryable_errors] || [StandardError],
        )
      end

      # Create a retry strategy from options
      # @param options [Hash] Strategy options
      # @return [RetryStrategy] A retry strategy instance
      def self.create_strategy(**options)
        backoff = options[:backoff] || :exponential
        max_attempts = options[:max_attempts] || 3
        max_delay = options[:max_delay]

        case backoff
        when :exponential
          ExponentialBackoff.new(
            initial_delay: options[:initial_delay] || 1,
            multiplier: options[:multiplier] || 2,
            max_attempts: max_attempts,
            max_delay: max_delay,
          )
        when :linear
          LinearBackoff.new(
            initial_delay: options[:initial_delay] || 1,
            increment: options[:increment] || 1,
            max_attempts: max_attempts,
            max_delay: max_delay,
          )
        when :constant
          ConstantDelay.new(
            delay: options[:delay] || 1,
            max_attempts: max_attempts,
            max_delay: max_delay,
          )
        when :none, false
          NoRetry.new
        else
          raise ArgumentError, "Unknown backoff strategy: #{backoff}"
        end
      end
    end

    # Tracks retry state for a job execution
    class RetryState
      attr_reader :job_name, :attempt, :errors, :started_at

      def initialize(job_name)
        @job_name = job_name
        @attempt = 1
        @errors = []
        @started_at = Time.now
      end

      # Record a failed attempt
      # @param error [Exception] The error that occurred
      def record_failure(error)
        @errors << {
          attempt: @attempt,
          error: error,
          timestamp: Time.now,
        }
        @attempt += 1
      end

      # Check if retry attempts have been exhausted
      # @param max_attempts [Integer] Maximum allowed attempts
      # @return [Boolean] true if attempts exhausted
      def exhausted?(max_attempts)
        @attempt > max_attempts
      end

      # Get the last error that occurred
      # @return [Exception, nil] The last error or nil
      def last_error
        @errors.last&.dig(:error)
      end

      # Get total execution time across all attempts
      # @return [Numeric] Total time in seconds
      def total_time
        Time.now - @started_at
      end

      # Get a summary of all retry attempts
      # @return [Hash] Summary data
      def summary
        {
          job_name: @job_name,
          total_attempts: @attempt - 1,
          total_time: total_time,
          errors: @errors.map do |err|
            {
              attempt: err[:attempt],
              error_class: err[:error].class.name,
              error_message: err[:error].message,
              timestamp: err[:timestamp],
            }
          end,
        }
      end
    end
  end
end
