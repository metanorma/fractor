# frozen_string_literal: true

require "spec_helper"

RSpec.describe Fractor::Workflow::CircuitBreakerOrchestrator do
  let(:orchestrator) do
    described_class.new(threshold: 3, timeout: 60, debug: false)
  end
  let(:job) { double("Job", name: "test_job") }

  describe "#initialize" do
    it "creates a circuit breaker with configured threshold" do
      expect(orchestrator.breaker.threshold).to eq(3)
    end

    it "creates a circuit breaker with configured timeout" do
      expect(orchestrator.breaker.timeout).to eq(60)
    end

    it "initializes with debug flag" do
      debug_orch = described_class.new(threshold: 3, debug: true)
      expect(debug_orch.debug).to be true
    end

    it "initializes counters to zero" do
      expect(orchestrator.instance_variable_get(:@execution_count)).to eq(0)
      expect(orchestrator.instance_variable_get(:@success_count)).to eq(0)
      expect(orchestrator.instance_variable_get(:@blocked_count)).to eq(0)
    end

    it "stores job name if provided" do
      orch_with_name = described_class.new(threshold: 3, job_name: "my_job")
      expect(orch_with_name.job_name).to eq("my_job")
    end
  end

  describe "#execute_with_breaker" do
    context "when circuit is closed" do
      it "executes the job and returns result" do
        result = orchestrator.execute_with_breaker(job) { |_j| "success" }

        expect(result).to eq("success")
        expect(orchestrator.instance_variable_get(:@execution_count)).to eq(1)
        expect(orchestrator.instance_variable_get(:@success_count)).to eq(1)
      end

      it "tracks failures" do
        begin
          orchestrator.execute_with_breaker(job) do |_j|
            raise StandardError, "failed"
          end
        rescue StandardError
          # Expected
        end

        expect(orchestrator.failure_count).to eq(1)
        expect(orchestrator.instance_variable_get(:@success_count)).to eq(0)
      end

      it "opens circuit after threshold failures" do
        threshold = orchestrator.breaker.threshold

        threshold.times do
          orchestrator.execute_with_breaker(job) do |_j|
            raise StandardError, "failed"
          end
        rescue StandardError
          # Expected
        end

        expect(orchestrator.open?).to be true
      end
    end

    context "when circuit is open" do
      it "blocks execution and raises CircuitOpenError" do
        # Open the circuit by exceeding threshold
        3.times do
          orchestrator.execute_with_breaker(job) do |_j|
            raise StandardError, "failed"
          end
        rescue StandardError
          # Expected
        end

        expect(orchestrator.open?).to be true

        expect do
          orchestrator.execute_with_breaker(job) { |_j| "success" }
        end.to raise_error(Fractor::Workflow::CircuitOpenError)
      end

      it "increments blocked count" do
        # Open the circuit
        3.times do
          orchestrator.execute_with_breaker(job) do |_j|
            raise StandardError, "failed"
          end
        rescue StandardError
          # Expected
        end

        begin
          orchestrator.execute_with_breaker(job) { |_j| "success" }
        rescue Fractor::Workflow::CircuitOpenError
          # Expected
        end

        expect(orchestrator.instance_variable_get(:@blocked_count)).to eq(1)
      end
    end

    context "when circuit is half-open" do
      it "allows limited test calls" do
        # Open the circuit
        3.times do
          orchestrator.execute_with_breaker(job) do |_j|
            raise StandardError, "failed"
          end
        rescue StandardError
          # Expected
        end

        # Wait for timeout to transition to half-open
        orchestrator.breaker.instance_variable_get(:@mutex).synchronize do
          orchestrator.breaker.instance_variable_set(:@last_failure_time,
                                                     Time.now - 61)
        end

        # Check state transition
        orchestrator.breaker.send(:check_state)
        expect(orchestrator.half_open?).to be true

        # Should allow execution in half-open state
        result = orchestrator.execute_with_breaker(job) { |_j| "success" }
        expect(result).to eq("success")
      end
    end
  end

  describe "#open?" do
    it "returns false initially" do
      expect(orchestrator.open?).to be false
    end

    it "returns true after threshold failures" do
      3.times do
        orchestrator.execute_with_breaker(job) do |_j|
          raise StandardError, "failed"
        end
      rescue StandardError
        # Expected
      end

      expect(orchestrator.open?).to be true
    end
  end

  describe "#closed?" do
    it "returns true initially" do
      expect(orchestrator.closed?).to be true
    end

    it "returns false after circuit opens" do
      3.times do
        orchestrator.execute_with_breaker(job) do |_j|
          raise StandardError, "failed"
        end
      rescue StandardError
        # Expected
      end

      expect(orchestrator.closed?).to be false
    end
  end

  describe "#half_open?" do
    it "returns false initially" do
      expect(orchestrator.half_open?).to be false
    end

    it "returns true after timeout when open" do
      # Open the circuit
      3.times do
        orchestrator.execute_with_breaker(job) do |_j|
          raise StandardError, "failed"
        end
      rescue StandardError
        # Expected
      end

      # Simulate timeout elapsed
      orchestrator.breaker.instance_variable_get(:@mutex).synchronize do
        orchestrator.breaker.instance_variable_set(:@last_failure_time,
                                                   Time.now - 61)
      end
      orchestrator.breaker.send(:check_state)

      expect(orchestrator.half_open?).to be true
    end
  end

  describe "#state" do
    it "returns :closed initially" do
      expect(orchestrator.state).to eq(:closed)
    end

    it "returns :open after threshold failures" do
      3.times do
        orchestrator.execute_with_breaker(job) do |_j|
          raise StandardError, "failed"
        end
      rescue StandardError
        # Expected
      end

      expect(orchestrator.state).to eq(:open)
    end
  end

  describe "#failure_count" do
    it "returns 0 initially" do
      expect(orchestrator.failure_count).to eq(0)
    end

    it "counts failures" do
      2.times do
        orchestrator.execute_with_breaker(job) do |_j|
          raise StandardError, "failed"
        end
      rescue StandardError
        # Expected
      end

      expect(orchestrator.failure_count).to eq(2)
    end
  end

  describe "#last_failure_time" do
    it "returns nil initially" do
      expect(orchestrator.last_failure_time).to be_nil
    end

    it "returns time of last failure" do
      before_time = Time.now
      begin
        orchestrator.execute_with_breaker(job) do |_j|
          raise StandardError, "failed"
        end
      rescue StandardError
        # Expected
      end

      expect(orchestrator.last_failure_time).to be >= before_time
    end
  end

  describe "#reset!" do
    it "resets circuit breaker to closed state" do
      # Open the circuit
      3.times do
        orchestrator.execute_with_breaker(job) do |_j|
          raise StandardError, "failed"
        end
      rescue StandardError
        # Expected
      end

      orchestrator.reset!

      expect(orchestrator.closed?).to be true
      expect(orchestrator.failure_count).to eq(0)
    end

    it "resets orchestrator counters" do
      orchestrator.execute_with_breaker(job) { |_j| "success" }
      orchestrator.reset!

      expect(orchestrator.instance_variable_get(:@execution_count)).to eq(0)
      expect(orchestrator.instance_variable_get(:@success_count)).to eq(0)
      expect(orchestrator.instance_variable_get(:@blocked_count)).to eq(0)
    end
  end

  describe "#stats" do
    it "returns combined stats from breaker and orchestrator" do
      orchestrator.execute_with_breaker(job) { |_j| "success" }

      stats = orchestrator.stats

      expect(stats[:state]).to eq(:closed)
      expect(stats[:failure_count]).to eq(0)
      expect(stats[:execution_count]).to eq(1)
      expect(stats[:success_count]).to eq(1)
      expect(stats[:blocked_count]).to eq(0)
    end
  end

  describe "#state_description" do
    it "returns description for closed state" do
      expect(orchestrator.state_description).to eq("CLOSED (normal operation)")
    end

    it "returns description for open state" do
      3.times do
        orchestrator.execute_with_breaker(job) do |_j|
          raise StandardError, "failed"
        end
      rescue StandardError
        # Expected
      end

      description = orchestrator.state_description
      expect(description).to include("OPEN")
      expect(description).to include("3/3")
    end

    it "returns description for half-open state" do
      # Open the circuit
      3.times do
        orchestrator.execute_with_breaker(job) do |_j|
          raise StandardError, "failed"
        end
      rescue StandardError
        # Expected
      end

      # Transition to half-open
      orchestrator.breaker.instance_variable_get(:@mutex).synchronize do
        orchestrator.breaker.instance_variable_set(:@last_failure_time,
                                                   Time.now - 61)
      end
      orchestrator.breaker.send(:check_state)

      description = orchestrator.state_description
      expect(description).to include("HALF_OPEN")
      expect(description).to include("testing recovery")
    end
  end

  describe "#execute_bypassing_breaker" do
    it "executes job regardless of circuit state" do
      # Open the circuit
      3.times do
        orchestrator.execute_with_breaker(job) do |_j|
          raise StandardError, "failed"
        end
      rescue StandardError
        # Expected
      end

      expect(orchestrator.open?).to be true

      # Bypass should still work
      result = orchestrator.execute_bypassing_breaker(job) { |_j| "bypassed" }
      expect(result).to eq("bypassed")
    end

    it "increments success count on success" do
      orchestrator.execute_bypassing_breaker(job) { |_j| "success" }

      expect(orchestrator.instance_variable_get(:@success_count)).to eq(1)
    end
  end

  describe "#open_circuit!" do
    it "manually opens the circuit" do
      expect(orchestrator.closed?).to be true

      orchestrator.open_circuit!

      expect(orchestrator.open?).to be true
    end
  end

  describe "#close_circuit!" do
    it "manually closes the circuit" do
      # Open the circuit
      3.times do
        orchestrator.execute_with_breaker(job) do |_j|
          raise StandardError, "failed"
        end
      rescue StandardError
        # Expected
      end

      expect(orchestrator.open?).to be true

      orchestrator.close_circuit!

      expect(orchestrator.closed?).to be true
    end
  end
end
