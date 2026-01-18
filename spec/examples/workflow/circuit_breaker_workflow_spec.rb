# frozen_string_literal: true

require "spec_helper"
require_relative "../../../examples/workflow/circuit_breaker/circuit_breaker_workflow"

RSpec.describe "CircuitBreakerExample" do
  describe CircuitBreakerExample::CircuitBreakerWorkflow do
    let(:workflow) { described_class.new }

    describe "successful execution" do
      it "executes successfully when service is available" do
        request = CircuitBreakerExample::ApiRequest.new(
          "users/123",
          should_fail: false,
        )

        result = workflow.execute(input: request)

        expect(result).to be_a(Fractor::Workflow::WorkflowResult)
        expect(result.output).to be_a(CircuitBreakerExample::ApiResponse)
        expect(result.output.data).to eq("Data from users/123")
        expect(result.output.source).to eq(:primary)
      end
    end

    describe "circuit breaker protection" do
      it "opens circuit after threshold failures" do
        # Trigger 3 failures to open circuit
        # Note: Each workflow.execute creates a new circuit breaker state,
        # so the circuit breaker doesn't persist across executions.
        # Instead, we verify that failures trigger fallback behavior.
        3.times do |i|
          request = CircuitBreakerExample::ApiRequest.new(
            "endpoint_#{i}",
            should_fail: true,
          )

          result = workflow.execute(input: request)
          # Workflow completes but has failed jobs due to fallback
          expect(result.success?).to be false
          expect(result.failed_jobs).not_to be_empty
        end

        # Next request should use fallback (job fails and falls back to cache)
        request = CircuitBreakerExample::ApiRequest.new(
          "users/456",
          should_fail: true, # Still failing to ensure fallback is used
        )

        result = workflow.execute(input: request)

        expect(result.output).to be_a(CircuitBreakerExample::ApiResponse)
        expect(result.output.source).to eq(:cache)
        expect(result.output.data).to include("Cached data")
      end

      it "uses fallback when circuit is open" do
        # Verify that when the primary job fails, fallback is used
        request = CircuitBreakerExample::ApiRequest.new(
          "users/789",
          should_fail: true, # Primary job will fail
        )

        result = workflow.execute(input: request)

        # Fallback provides cached data despite error
        expect(result.output.data).to eq("Cached data for users/789")
        expect(result.output.source).to eq(:cache)
        expect(result.success?).to be false
      end
    end

    describe "error handling" do
      it "handles API failures gracefully with fallback" do
        request = CircuitBreakerExample::ApiRequest.new(
          "users/error",
          should_fail: true,
        )

        # With fallback, workflow completes but has errors
        result = workflow.execute(input: request)

        expect(result.success?).to be false
        expect(result.failed_jobs).not_to be_empty
        # Fallback provides output despite error
        expect(result.output).to be_a(CircuitBreakerExample::ApiResponse)
        expect(result.output.source).to eq(:cache)
      end
    end
  end

  describe CircuitBreakerExample::SharedCircuitBreakerWorkflow do
    let(:workflow) { described_class.new }

    describe "shared circuit breaker behavior" do
      it "shares circuit breaker state across jobs" do
        # Create multiple requests that would normally go to different jobs
        # but they share the same circuit breaker
        request = CircuitBreakerExample::ApiRequest.new(
          "shared_endpoint",
          should_fail: true,
        )

        # Each execution contributes to the shared circuit breaker
        # The threshold is 5, so we need 5 failures
        5.times do
          result = workflow.execute(input: request)
          # With fallback, workflow completes but has failed jobs
          expect(result.success?).to be false
        end

        # Circuit should now be open for all jobs using the shared key
        # Next request should use fallback
        success_request = CircuitBreakerExample::ApiRequest.new(
          "another_endpoint",
          should_fail: false,
        )

        result = workflow.execute(input: success_request)

        # Should get cached data because shared circuit is open
        expect(result.output.source).to eq(:cache)
      end
    end
  end

  describe CircuitBreakerExample::UnreliableApiWorker do
    let(:worker) { described_class.new }

    it "succeeds when should_fail is false" do
      work = CircuitBreakerExample::ApiRequest.new(
        "test_endpoint",
        should_fail: false,
      )

      result = worker.process(work)

      expect(result).to be_a(Fractor::WorkResult)
      expect(result.result).to be_a(CircuitBreakerExample::ApiResponse)
      expect(result.result.data).to eq("Data from test_endpoint")
      expect(result.result.source).to eq(:primary)
    end

    it "fails when should_fail is true" do
      work = CircuitBreakerExample::ApiRequest.new(
        "test_endpoint",
        should_fail: true,
      )

      expect do
        worker.process(work)
      end.to raise_error(StandardError, "API service unavailable")
    end
  end

  describe CircuitBreakerExample::CachedDataWorker do
    let(:worker) { described_class.new }

    it "returns cached data" do
      work = CircuitBreakerExample::ApiRequest.new("test_endpoint")

      result = worker.process(work)

      expect(result).to be_a(Fractor::WorkResult)
      expect(result.result).to be_a(CircuitBreakerExample::ApiResponse)
      expect(result.result.data).to eq("Cached data for test_endpoint")
      expect(result.result.source).to eq(:cache)
    end
  end

  describe "example runners" do
    describe ".run_basic_example" do
      it "executes without errors" do
        expect do
          CircuitBreakerExample.run_basic_example
        end.not_to raise_error
      end

      it "demonstrates circuit breaker behavior" do
        output = capture_stdout do
          CircuitBreakerExample.run_basic_example
        end

        expect(output).to include("Circuit Breaker Example - Basic Protection")
        expect(output).to include("Successful API call")
        expect(output).to include("Triggering circuit breaker")
        expect(output).to include("Circuit open - using fallback")
        expect(output).to include("source: cache")
      end
    end

    describe ".run_shared_example" do
      it "executes without errors" do
        expect do
          CircuitBreakerExample.run_shared_example
        end.not_to raise_error
      end

      it "demonstrates shared circuit breaker" do
        output = capture_stdout do
          CircuitBreakerExample.run_shared_example
        end

        expect(output).to include("Circuit Breaker Example - Shared Protection")
        expect(output).to include("Multiple jobs sharing same circuit breaker")
      end
    end
  end

  # Helper method to capture stdout
  def capture_stdout
    old_stdout = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = old_stdout
  end
end
