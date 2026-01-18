# frozen_string_literal: true

require_relative "circuit_breaker"

module Fractor
  class Workflow
    # Orchestrates circuit breaker logic for workflow job execution.
    # Wraps a CircuitBreaker and provides workflow-specific integration.
    #
    # @example Basic usage
    #   orchestrator = CircuitBreakerOrchestrator.new(threshold: 5, timeout: 60)
    #   result = orchestrator.execute_with_breaker(job) { |job| execute_job(job) }
    class CircuitBreakerOrchestrator
      attr_reader :breaker, :debug, :job_name

      # Initialize a new circuit breaker orchestrator.
      #
      # @param threshold [Integer] Number of failures before opening circuit
      # @param timeout [Integer] Seconds to wait before trying half-open
      # @param half_open_calls [Integer] Number of test calls in half-open
      # @param job_name [String] Optional job name for logging
      # @param debug [Boolean] Whether to enable debug logging
      def initialize(threshold: 5, timeout: 60, half_open_calls: 3,
job_name: nil, debug: false)
        @breaker = CircuitBreaker.new(
          threshold: threshold,
          timeout: timeout,
          half_open_calls: half_open_calls,
        )
        @job_name = job_name
        @debug = debug
        @execution_count = 0
        @success_count = 0
        @blocked_count = 0
      end

      # Execute a job with circuit breaker protection.
      #
      # @param job [Job] The job to execute
      # @yield [Job] Block that executes the job
      # @return [Object] The execution result
      # @raise [CircuitOpenError] If circuit is open
      def execute_with_breaker(job, &)
        @execution_count += 1

        log_debug "Executing job '#{job.name}' with circuit breaker protection"

        check_and_call_breaker(job, &)
      rescue CircuitOpenError => e
        @blocked_count += 1
        log_debug "Job '#{job.name}' blocked by circuit breaker: #{e.message}"
        raise
      rescue StandardError => e
        log_debug "Job '#{job.name}' failed with #{e.class}"
        raise
      end

      # Check if the circuit is currently open.
      #
      # @return [Boolean] true if circuit is open
      def open?
        @breaker.open?
      end

      # Check if the circuit is currently closed.
      #
      # @return [Boolean] true if circuit is closed
      def closed?
        @breaker.closed?
      end

      # Check if the circuit is currently half-open.
      #
      # @return [Boolean] true if circuit is half-open
      def half_open?
        @breaker.half_open?
      end

      # Get the current circuit breaker state.
      #
      # @return [Symbol] The state (:closed, :open, :half_open)
      def state
        @breaker.state
      end

      # Get the failure count.
      #
      # @return [Integer] Number of failures recorded
      def failure_count
        @breaker.failure_count
      end

      # Get the last failure time.
      #
      # @return [Time, nil] Last failure time or nil
      def last_failure_time
        @breaker.last_failure_time
      end

      # Reset the circuit breaker to closed state.
      def reset!
        @breaker.reset
        @execution_count = 0
        @success_count = 0
        @blocked_count = 0
        log_debug "Circuit breaker reset for job '#{@job_name}'"
      end

      # Get circuit breaker statistics including orchestrator metrics.
      #
      # @return [Hash] Statistics and metrics
      def stats
        @breaker.stats.merge(
          execution_count: @execution_count,
          success_count: @success_count,
          blocked_count: @blocked_count,
        )
      end

      # Get the current state as a human-readable string.
      #
      # @return [String] State description
      def state_description
        case state
        when CircuitBreaker::STATE_CLOSED
          "CLOSED (normal operation)"
        when CircuitBreaker::STATE_OPEN
          "OPEN (blocking requests, #{failure_count}/#{@breaker.threshold} failures)"
        when CircuitBreaker::STATE_HALF_OPEN
          "HALF_OPEN (testing recovery, #{@breaker.instance_variable_get(:@success_count)}/#{@breaker.half_open_calls} successes)"
        else
          "UNKNOWN"
        end
      end

      # Try to execute the job regardless of circuit state.
      # This bypasses the circuit breaker but still tracks results.
      #
      # @param job [Job] The job to execute
      # @yield [Job] Block that executes the job
      # @return [Object] The execution result
      def execute_bypassing_breaker(job)
        @execution_count += 1

        log_debug "Executing job '#{job.name}' bypassing circuit breaker"

        result = yield(job)
        @success_count += 1
        result
      rescue StandardError => e
        log_debug "Bypassed execution failed: #{e.class}"
        raise
      end

      # Manually open the circuit (for testing or emergency).
      def open_circuit!
        @breaker.instance_variable_get(:@mutex).synchronize do
          @breaker.instance_variable_set(:@state, CircuitBreaker::STATE_OPEN)
          @breaker.instance_variable_set(:@failure_count, @breaker.threshold)
          @breaker.instance_variable_set(:@last_failure_time, Time.now)
        end
        log_debug "Circuit manually opened for job '#{@job_name}'"
      end

      # Manually close the circuit (for testing or recovery).
      def close_circuit!
        @breaker.reset
        log_debug "Circuit manually closed for job '#{@job_name}'"
      end

      private

      # Check circuit state and call the breaker.
      #
      # @param job [Job] The job to execute
      # @yield [Job] Block that executes the job
      # @return [Object] The execution result
      def check_and_call_breaker(job, &)
        result = @breaker.call(&)

        @success_count += 1
        log_success(job) if @debug

        result
      end

      # Log a successful execution.
      #
      # @param job [Job] The job that succeeded
      def log_success(job)
        state_info = case state
                     when CircuitBreaker::STATE_CLOSED then "(closed)"
                     when CircuitBreaker::STATE_HALF_OPEN then "(half-open, recovering)"
                     else ""
                     end

        puts "[CircuitBreakerOrchestrator] Job '#{job.name}' succeeded #{state_info}" if @debug
      end

      # Log a debug message.
      #
      # @param message [String] The message to log
      def log_debug(message)
        puts "[CircuitBreakerOrchestrator] #{message}" if @debug
      end
    end
  end
end
