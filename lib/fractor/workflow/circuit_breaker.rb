# frozen_string_literal: true

module Fractor
  class Workflow
    # Circuit breaker implementation for fault tolerance
    #
    # The circuit breaker has three states:
    # - Closed: Normal operation, requests pass through
    # - Open: Failure threshold exceeded, requests fail fast
    # - Half-Open: Testing if service recovered, limited requests allowed
    #
    # @example Basic usage
    #   breaker = CircuitBreaker.new(threshold: 5, timeout: 60)
    #   breaker.call do
    #     # Risky operation
    #   end
    class CircuitBreaker
      # Circuit breaker states
      STATE_CLOSED = :closed
      STATE_OPEN = :open
      STATE_HALF_OPEN = :half_open

      attr_reader :state, :failure_count, :last_failure_time,
                  :threshold, :timeout, :half_open_calls

      # Initialize a new circuit breaker
      #
      # @param threshold [Integer] Number of failures before opening circuit
      # @param timeout [Integer] Seconds to wait before trying half-open
      # @param half_open_calls [Integer] Number of test calls in half-open
      def initialize(threshold: 5, timeout: 60, half_open_calls: 3)
        @threshold = threshold
        @timeout = timeout
        @half_open_calls = half_open_calls
        @state = STATE_CLOSED
        @failure_count = 0
        @success_count = 0
        @last_failure_time = nil
        @mutex = Mutex.new
        @just_transitioned_to_half_open = false
      end

      # Execute a block with circuit breaker protection
      #
      # @yield Block to execute
      # @return [Object] Result of the block
      # @raise [CircuitOpenError] If circuit is open
      def call(&)
        check_state

        if open?
          raise CircuitOpenError,
                "Circuit breaker is open (#{failure_count} failures)"
        end

        execute_with_breaker(&)
      end

      # Check if circuit breaker is closed
      #
      # @return [Boolean] True if closed
      def closed?
        state == STATE_CLOSED
      end

      # Check if circuit breaker is open
      #
      # @return [Boolean] True if open
      def open?
        state == STATE_OPEN
      end

      # Check if circuit breaker is half-open
      #
      # @return [Boolean] True if half-open
      def half_open?
        state == STATE_HALF_OPEN
      end

      # Reset the circuit breaker to closed state
      def reset
        @mutex.synchronize do
          @state = STATE_CLOSED
          @failure_count = 0
          @success_count = 0
          @last_failure_time = nil
        end
      end

      # Get circuit breaker statistics
      #
      # @return [Hash] Statistics including state, counts, and timing
      def stats
        {
          state: state,
          failure_count: failure_count,
          success_count: @success_count,
          last_failure_time: last_failure_time,
          threshold: threshold,
          timeout: timeout,
        }
      end

      private

      # Check and update circuit breaker state
      def check_state
        @mutex.synchronize do
          if open? && timeout_elapsed?
            # Transition from open to half-open
            @state = STATE_HALF_OPEN
            @success_count = 0
            @last_failure_time = nil # Clear to track new failures in half-open
            @just_transitioned_to_half_open = true
          end
        end
      end

      # Execute block with circuit breaker logic
      #
      # @yield Block to execute
      # @return [Object] Result of the block
      def execute_with_breaker
        result = yield
        on_success
        result
      rescue StandardError => e
        on_failure
        raise e
      end

      # Handle successful execution
      def on_success
        @mutex.synchronize do
          if half_open?
            @success_count += 1
            if @success_count >= half_open_calls
              # Transition from half-open to closed
              @state = STATE_CLOSED
              @failure_count = 0
            end
          else
            # Reset failure count on success in closed state
            @failure_count = 0
          end
        end
      end

      # Handle failed execution
      def on_failure
        @mutex.synchronize do
          @failure_count += 1
          @last_failure_time = Time.now

          if half_open?
            if @just_transitioned_to_half_open
              # Just transitioned to half-open, stay there to allow recovery attempt
              @just_transitioned_to_half_open = false
            else
              # Already in half-open and failed again, reopen circuit
              @state = STATE_OPEN
            end
          elsif @failure_count >= threshold
            # Threshold exceeded, open circuit
            @state = STATE_OPEN
          end
        end
      end

      # Check if timeout has elapsed since last failure
      #
      # @return [Boolean] True if timeout elapsed
      def timeout_elapsed?
        return false unless last_failure_time

        Time.now - last_failure_time >= timeout
      end
    end

    # Error raised when circuit breaker is open
    class CircuitOpenError < StandardError; end
  end
end
