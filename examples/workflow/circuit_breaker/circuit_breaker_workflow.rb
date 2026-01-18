# frozen_string_literal: true

require_relative "../../../lib/fractor"

# This example demonstrates circuit breaker pattern for fault tolerance
# in workflows. The circuit breaker prevents cascading failures by
# failing fast when a service is unavailable.
module CircuitBreakerExample
  # Input data for the workflow
  class ApiRequest < Fractor::Work
    attr_reader :endpoint, :should_fail

    def initialize(endpoint, should_fail: false)
      @endpoint = endpoint
      @should_fail = should_fail
      super(endpoint)
    end
  end

  # Output data from the workflow
  class ApiResponse
    attr_reader :data, :source

    def initialize(data:, source: :primary)
      @data = data
      @source = source
    end
  end

  # Worker that simulates calling an unreliable external API
  class UnreliableApiWorker < Fractor::Worker
    input_type ApiRequest
    output_type ApiResponse

    def process(work)
      if work.should_fail
        raise StandardError, "API service unavailable"
      end

      # Simulate API call
      sleep 0.1
      result = ApiResponse.new(
        data: "Data from #{work.endpoint}",
        source: :primary
      )

      Fractor::WorkResult.new(result: result, work: work)
    end
  end

  # Worker that provides fallback data from cache
  class CachedDataWorker < Fractor::Worker
    input_type ApiRequest
    output_type ApiResponse

    def process(work)
      # Simulate cache lookup
      sleep 0.05
      result = ApiResponse.new(
        data: "Cached data for #{work.endpoint}",
        source: :cache
      )

      Fractor::WorkResult.new(result: result, work: work)
    end
  end

  # Workflow demonstrating circuit breaker with fallback
  class CircuitBreakerWorkflow < Fractor::Workflow
    workflow "circuit-breaker-example" do
      input_type ApiRequest
      output_type ApiResponse
      start_with "fetch_from_api"

      # Primary API job with circuit breaker protection
      job "fetch_from_api" do
        runs_with UnreliableApiWorker
        inputs_from_workflow

        # Circuit breaker configuration:
        # - Opens after 3 failures
        # - Stays open for 60 seconds
        # - Allows 2 test calls when half-open
        circuit_breaker threshold: 3,
                        timeout: 60,
                        half_open_calls: 2

        # Fallback to cache when circuit opens
        fallback_to "fetch_from_cache"

        # Log circuit breaker events
        on_error do |error, _context|
          puts "❌ API call failed: #{error.message}"
        end

        outputs_to_workflow
        terminates_workflow
      end

      # Fallback job that uses cached data
      job "fetch_from_cache" do
        runs_with CachedDataWorker
        inputs_from_workflow
        outputs_to_workflow
        terminates_workflow
      end
    end
  end

  # Workflow demonstrating shared circuit breaker across jobs
  class SharedCircuitBreakerWorkflow < Fractor::Workflow
    workflow "shared-circuit-breaker-example" do
      input_type ApiRequest
      output_type ApiResponse
      start_with "fetch_user_data"

      # First API job using shared circuit breaker
      job "fetch_user_data" do
        runs_with UnreliableApiWorker
        inputs_from_workflow

        # Use shared circuit breaker for the API service
        circuit_breaker threshold: 5,
                        timeout: 60,
                        half_open_calls: 3,
                        shared_key: "external_api"

        fallback_to "fetch_cached_user_data"
      end

      # Second API job sharing the same circuit breaker
      job "fetch_profile_data" do
        runs_with UnreliableApiWorker
        inputs_from_workflow
        needs "fetch_user_data"

        # Same shared_key means same circuit breaker instance
        circuit_breaker threshold: 5,
                        timeout: 60,
                        half_open_calls: 3,
                        shared_key: "external_api"

        fallback_to "fetch_cached_profile_data"
      end

      # Fallback jobs
      job "fetch_cached_user_data" do
        runs_with CachedDataWorker
        inputs_from_workflow
      end

      job "fetch_cached_profile_data" do
        runs_with CachedDataWorker
        inputs_from_workflow
      end
    end
  end

  # Demonstration runner
  def self.run_basic_example
    puts "\n" + "=" * 60
    puts "Circuit Breaker Example - Basic Protection"
    puts "=" * 60

    workflow = CircuitBreakerWorkflow.new

    # Successful request
    puts "\n1️⃣  Successful API call:"
    request = ApiRequest.new("users/123", should_fail: false)
    result = workflow.execute(input: request)
    puts "✅ Result: #{result.output.data} (source: #{result.output.source})"

    # Trigger circuit breaker with failures
    puts "\n2️⃣  Triggering circuit breaker (3 failures):"
    3.times do |i|
      request = ApiRequest.new("users/#{i}", should_fail: true)
      result = workflow.execute(input: request)
      if result.success?
        puts "   Attempt #{i + 1}: Success"
      else
        puts "   Attempt #{i + 1}: Failed (using fallback)"
      end
    end

    # Circuit should now be open - fallback activated
    puts "\n3️⃣  Circuit open - using fallback:"
    request = ApiRequest.new("users/456", should_fail: true)  # Still failing to show fallback
    result = workflow.execute(input: request)
    puts "✅ Result: #{result.output.data} (source: #{result.output.source})"
    puts "   Note: Got cached data because primary failed"

    puts "\n" + "=" * 60
  end

  def self.run_shared_example
    puts "\n" + "=" * 60
    puts "Circuit Breaker Example - Shared Protection"
    puts "=" * 60

    workflow = SharedCircuitBreakerWorkflow.new

    puts "\n1️⃣  Multiple jobs sharing same circuit breaker:"
    puts "   Each failure contributes to the shared threshold"

    # Cause some failures
    3.times do |i|
      request = ApiRequest.new("endpoint_#{i}", should_fail: true)
      result = workflow.execute(input: request)
      if result.success?
        puts "   Failure #{i + 1}: Unexpected success"
      else
        puts "   Failure #{i + 1}: Building up to threshold..."
      end
    end

    puts "\n   Shared circuit breaker protects all jobs using it"
    puts "=" * 60
  end
end

# Run examples if executed directly
if __FILE__ == $PROGRAM_NAME
  CircuitBreakerExample.run_basic_example
  CircuitBreakerExample.run_shared_example
end
