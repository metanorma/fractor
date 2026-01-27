# frozen_string_literal: true

module Fractor
  class Workflow
    # Handles all logging operations for workflow execution.
    # Provides a clean separation of logging concerns from execution logic.
    # NOTE: This is different from the WorkflowLogger in logger.rb which is a
    # structured logging wrapper. This class extracts logging logic from the executor.
    class WorkflowExecutionLogger
      # Initialize the logger with a context logger.
      #
      # @param context_logger [Logger, nil] The logger from the workflow context
      def initialize(context_logger)
        @logger = context_logger
      end

      # Log workflow start.
      #
      # @param workflow_name [String] Name of the workflow
      # @param correlation_id [String, nil] Correlation ID for tracking
      def workflow_start(workflow_name, correlation_id)
        return unless @logger

        @logger.info(
          "Workflow starting",
          workflow: workflow_name,
          correlation_id: correlation_id,
        )
      end

      # Log workflow completion.
      #
      # @param workflow_name [String] Name of the workflow
      # @param duration [Float] Execution duration in seconds
      # @param jobs_completed [Integer] Number of jobs completed
      # @param jobs_failed [Integer] Number of jobs failed
      def workflow_complete(workflow_name, duration, jobs_completed:,
jobs_failed:)
        return unless @logger

        @logger.info(
          "Workflow complete",
          workflow: workflow_name,
          duration_ms: (duration * 1000).round(2),
          jobs_completed: jobs_completed,
          jobs_failed: jobs_failed,
        )
      end

      # Log job start.
      #
      # @param job_name [String] Name of the job
      # @param worker_class [String] Class name of the worker
      def job_start(job_name, worker_class)
        return unless @logger

        @logger.info(
          "Job starting",
          job: job_name,
          worker: worker_class,
        )
      end

      # Log job completion.
      #
      # @param job_name [String] Name of the job
      # @param duration [Float] Execution duration in seconds
      def job_complete(job_name, duration)
        return unless @logger

        @logger.info(
          "Job complete",
          job: job_name,
          duration_ms: (duration * 1000).round(2),
        )
      end

      # Log job error.
      #
      # @param job_name [String] Name of the job
      # @param error [Exception] The error that occurred
      # @param has_fallback [Boolean] Whether a fallback job is available
      def job_error(job_name, error, has_fallback: false)
        return unless @logger

        # Log at WARN level if fallback is available (error is handled),
        # otherwise log at ERROR level (error causes workflow failure)
        log_method = has_fallback ? @logger.method(:warn) : @logger.method(:error)

        log_method.call(
          "Job '#{job_name}' encountered error: #{error}",
          job: job_name,
          error: error.class.name,
        )
      end

      # Log retry attempt.
      #
      # @param job_name [String] Name of the job
      # @param attempt [Integer] Current attempt number
      # @param max_attempts [Integer] Maximum number of attempts
      # @param delay [Float] Delay before this retry in seconds
      # @param last_error [Exception, nil] Last error that occurred
      def retry_attempt(job_name, attempt, max_attempts, delay, last_error: nil)
        return unless @logger

        @logger.warn(
          "Job retry attempt",
          job: job_name,
          attempt: attempt,
          max_attempts: max_attempts,
          delay_seconds: delay,
          last_error: last_error&.message,
        )
      end

      # Log retry success.
      #
      # @param job_name [String] Name of the job
      # @param attempt [Integer] Successful attempt number
      # @param total_attempts [Integer] Total number of attempts made
      # @param total_time [Float] Total time spent retrying in seconds
      def retry_success(job_name, attempt, total_attempts, total_time)
        return unless @logger

        @logger.info(
          "Job retry succeeded",
          job: job_name,
          successful_attempt: attempt,
          total_attempts: total_attempts,
          total_time: total_time,
        )
      end

      # Log retry exhausted.
      #
      # @param job_name [String] Name of the job
      # @param attempts [Integer] Total number of attempts made
      # @param total_time [Float] Total time spent retrying in seconds
      # @param errors [Array<Exception>] All errors that occurred
      def retry_exhausted(job_name, attempts, total_time, errors)
        return unless @logger

        @logger.error(
          "Job retry attempts exhausted",
          job: job_name,
          total_attempts: attempts,
          total_time: total_time,
          errors: errors,
        )
      end

      # Log fallback job execution.
      #
      # @param job_name [String] Name of the original job
      # @param fallback_job_name [String] Name of the fallback job
      # @param original_error [Exception] The error that triggered fallback
      def fallback_execution(job_name, fallback_job_name, original_error)
        return unless @logger

        @logger.warn(
          "Executing fallback job",
          job: job_name,
          fallback_job: fallback_job_name,
          original_error: original_error.message,
        )
      end

      # Log fallback job failure.
      #
      # @param job_name [String] Name of the original job
      # @param fallback_job_name [String] Name of the fallback job
      # @param error [Exception] The error that occurred in fallback
      def fallback_failed(job_name, fallback_job_name, error)
        return unless @logger

        @logger.error(
          "Fallback job failed",
          job: job_name,
          fallback_job: fallback_job_name,
          error: error.message,
        )
      end

      # Log circuit breaker state.
      #
      # @param job_name [String] Name of the job
      # @param state [Symbol] Current circuit breaker state
      # @param failure_count [Integer] Number of failures
      # @param threshold [Integer] Failure threshold
      def circuit_breaker_state(job_name, state, failure_count:, threshold:)
        return unless @logger
        return if state == :closed

        @logger.warn(
          "Circuit breaker state",
          job: job_name,
          state: state,
          failure_count: failure_count,
          threshold: threshold,
        )
      end

      # Log circuit breaker open.
      #
      # @param job_name [String] Name of the job
      # @param failure_count [Integer] Number of failures
      # @param threshold [Integer] Failure threshold
      # @param last_failure [Time, nil] Time of last failure
      def circuit_breaker_open(job_name, failure_count, threshold,
last_failure: nil)
        return unless @logger

        @logger.error(
          "Circuit breaker open",
          job: job_name,
          failure_count: failure_count,
          threshold: threshold,
          last_failure: last_failure,
        )
      end

      # Log work added to dead letter queue.
      #
      # @param job_name [String] Name of the job
      # @param error [Exception] The error that occurred
      # @param dlq_size [Integer] Current size of the dead letter queue
      def added_to_dead_letter_queue(job_name, error, dlq_size)
        return unless @logger

        @logger.warn(
          "Work added to Dead Letter Queue",
          job: job_name,
          error: error.class.name,
          message: error.message,
          dlq_size: dlq_size,
        )
      end
    end
  end
end
