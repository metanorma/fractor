# frozen_string_literal: true

require_relative "circuit_breaker_orchestrator"

module Fractor
  class Workflow
    # Registry for managing circuit breakers across jobs
    #
    # Provides centralized circuit breaker management, allowing multiple
    # jobs to share circuit breakers or have isolated ones.
    #
    # @example Shared circuit breaker
    #   registry = CircuitBreakerRegistry.new
    #   breaker = registry.get_or_create("api", threshold: 5)
    #
    # @example Per-job circuit breaker
    #   registry = CircuitBreakerRegistry.new
    #   breaker = registry.get_or_create("job_123", threshold: 3)
    #
    # @example Circuit breaker orchestrator
    #   registry = CircuitBreakerRegistry.new
    #   orchestrator = registry.get_or_create_orchestrator("api", threshold: 5, job_name: "my_job")
    class CircuitBreakerRegistry
      def initialize
        @breakers = {}
        @orchestrators = {}
        @mutex = Mutex.new
      end

      # Get or create a circuit breaker
      #
      # @param key [String] Unique identifier for the circuit breaker
      # @param options [Hash] Circuit breaker options
      # @option options [Integer] :threshold Failure threshold
      # @option options [Integer] :timeout Timeout in seconds
      # @option options [Integer] :half_open_calls Test calls in half-open
      # @return [CircuitBreaker] The circuit breaker
      def get_or_create(key, **options)
        @mutex.synchronize do
          @breakers[key] ||= CircuitBreaker.new(**options)
        end
      end

      # Get or create a circuit breaker orchestrator
      #
      # @param key [String] Unique identifier for the circuit breaker
      # @param options [Hash] Circuit breaker orchestrator options
      # @option options [Integer] :threshold Failure threshold
      # @option options [Integer] :timeout Timeout in seconds
      # @option options [Integer] :half_open_calls Test calls in half-open
      # @option options [String] :job_name Job name for logging
      # @option options [Boolean] :debug Debug logging flag
      # @return [CircuitBreakerOrchestrator] The circuit breaker orchestrator
      def get_or_create_orchestrator(key, **options)
        @mutex.synchronize do
          @orchestrators[key] ||= CircuitBreakerOrchestrator.new(**options)
        end
      end

      # Get an existing circuit breaker
      #
      # @param key [String] Unique identifier for the circuit breaker
      # @return [CircuitBreaker, nil] The circuit breaker or nil
      def get(key)
        @breakers[key]
      end

      # Get an existing circuit breaker orchestrator
      #
      # @param key [String] Unique identifier for the orchestrator
      # @return [CircuitBreakerOrchestrator, nil] The orchestrator or nil
      def get_orchestrator(key)
        @orchestrators[key]
      end

      # Remove a circuit breaker
      #
      # @param key [String] Unique identifier for the circuit breaker
      # @return [CircuitBreaker, CircuitBreakerOrchestrator, nil] The removed object or nil
      def remove(key)
        @mutex.synchronize do
          @breakers.delete(key) || @orchestrators.delete(key)
        end
      end

      # Reset all circuit breakers and orchestrators
      def reset_all
        @mutex.synchronize do
          @breakers.each_value(&:reset)
          @orchestrators.each_value(&:reset!)
        end
      end

      # Get statistics for all circuit breakers and orchestrators
      #
      # @return [Hash] Map of key to circuit breaker/orchestrator statistics
      def all_stats
        breakers_stats = @breakers.transform_values(&:stats)
        orchestrators_stats = @orchestrators.transform_values(&:stats)
        breakers_stats.merge(orchestrators_stats)
      end

      # Clear all circuit breakers and orchestrators
      def clear
        @mutex.synchronize do
          @breakers.clear
          @orchestrators.clear
        end
      end
    end
  end
end
