# frozen_string_literal: true

require_relative "retry_config"

module Fractor
  class Workflow
    # Orchestrates retry logic for workflow job execution.
    # Handles retry strategies, backoff calculations, and attempt tracking.
    #
    # @example Basic usage
    #   config = RetryConfig.from_options(backoff: :exponential, max_attempts: 3)
    #   orchestrator = RetryOrchestrator.new(config, debug: true)
    #   result = orchestrator.execute_with_retry(job) { |job| execute_job(job) }
    class RetryOrchestrator
      attr_reader :retry_config, :debug, :attempts

      # Initialize a new retry orchestrator.
      #
      # @param retry_config [RetryConfig] The retry configuration
      # @param debug [Boolean] Whether to enable debug logging
      def initialize(retry_config, debug: false)
        @retry_config = retry_config
        @debug = debug
        @attempts = 0
        @last_error = nil
        @all_errors = []
        @started_at = nil
      end

      # Execute a job with retry logic.
      # Retries the job execution according to the retry strategy configuration.
      #
      # @param job [Job] The job to execute
      # @yield [Job] Block that executes the job
      # @return [Object] The execution result
      # @raise [StandardError] If all retries are exhausted
      def execute_with_retry(job)
        reset!

        @started_at = Time.now

        loop do
          @attempts += 1

          log_debug "Executing job '#{job.name}', attempt #{@attempts}"

          result = yield job

          # If we got here without error, execution succeeded
          log_retry_success(job) if @attempts > 1
          return result
        rescue StandardError => e
          @last_error = e

          # Track all errors for DLQ entry
          @all_errors << {
            attempt: @attempts,
            error: e,
            timestamp: Time.now,
          }

          # Check if error is retryable
          unless @retry_config.retryable?(e)
            log_debug "Error #{e.class} is not retryable, failing immediately"
            raise e
          end

          # Record the failure and check if we've exhausted retries
          if exhausted?(@retry_config.max_attempts)
            log_retry_exhausted(job)
            raise e
          end

          # Calculate delay for this attempt
          delay = calculate_delay(@attempts)

          # Log retry attempt
          log_retry_attempt(job, delay)

          # Wait before retrying
          sleep(delay) if delay.positive?
        end
      end

      # Check if a retry should be attempted.
      #
      # @param attempt [Integer] The current attempt number
      # @param error [Exception] The error that occurred
      # @return [Boolean] true if retry should be attempted
      def should_retry?(attempt, error)
        return false if exhausted?(@retry_config.max_attempts)

        @retry_config.retryable?(error)
      end

      # Calculate the delay before the next retry attempt.
      #
      # @param attempt [Integer] The attempt number
      # @return [Numeric] The delay in seconds
      def calculate_delay(attempt)
        @retry_config.delay_for(attempt)
      end

      # Get the last error that occurred during retry.
      #
      # @return [Exception, nil] The last error or nil
      def last_error
        @last_error
      end

      # Check if all retry attempts are exhausted.
      #
      # @param max_attempts [Integer] Maximum number of attempts
      # @return [Boolean] true if retries are exhausted
      def exhausted?(max_attempts)
        @attempts >= max_attempts
      end

      # Reset the attempt counter and state.
      def reset!
        @attempts = 0
        @last_error = nil
        @all_errors = []
        @started_at = nil
      end

      # Get the current retry state information.
      #
      # @return [Hash] Retry state details
      def state
        {
          attempts: @attempts,
          max_attempts: @retry_config.max_attempts,
          last_error: @last_error&.class&.name,
          exhausted: exhausted?(@retry_config.max_attempts),
          all_errors: @all_errors.map do |err|
            {
              attempt: err[:attempt],
              error_class: err[:error].class.name,
              error_message: err[:error].message,
              timestamp: err[:timestamp],
            }
          end,
          total_time: @started_at ? Time.now - @started_at : 0
        }
      end

      private

      # Log a successful retry.
      #
      # @param job [Job] The job that succeeded
      def log_retry_success(job)
        puts "[RetryOrchestrator] Job '#{job.name}' succeeded on attempt #{@attempts}" if @debug
      end

      # Log that retries are exhausted.
      #
      # @param job [Job] The job that failed
      def log_retry_exhausted(job)
        puts "[RetryOrchestrator] Job '#{job.name}' retries exhausted after #{@attempts} attempts" if @debug
      end

      # Log a retry attempt.
      #
      # @param job [Job] The job being retried
      # @param delay [Numeric] The delay before next attempt
      def log_retry_attempt(job, delay)
        message = "[RetryOrchestrator] Retrying job '#{job.name}' (attempt #{@attempts + 1}"
        message += " after #{delay}s delay" if delay.positive?
        message += ")"

        puts message if @debug
      end

      # Log a debug message.
      #
      # @param message [String] The message to log
      def log_debug(message)
        puts "[RetryOrchestrator] #{message}" if @debug
      end
    end
  end
end
