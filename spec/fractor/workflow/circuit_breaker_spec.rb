# frozen_string_literal: true

require "spec_helper"
require_relative "../../../lib/fractor/workflow/circuit_breaker"

RSpec.describe Fractor::Workflow::CircuitBreaker do
  let(:threshold) { 3 }
  let(:timeout) { 60 }
  let(:half_open_calls) { 2 }
  let(:breaker) do
    described_class.new(
      threshold: threshold,
      timeout: timeout,
      half_open_calls: half_open_calls,
    )
  end

  describe "#initialize" do
    it "initializes with default values" do
      breaker = described_class.new
      expect(breaker.threshold).to eq(5)
      expect(breaker.timeout).to eq(60)
      expect(breaker.half_open_calls).to eq(3)
      expect(breaker.state).to eq(:closed)
      expect(breaker.failure_count).to eq(0)
    end

    it "initializes with custom values" do
      expect(breaker.threshold).to eq(3)
      expect(breaker.timeout).to eq(60)
      expect(breaker.half_open_calls).to eq(2)
    end
  end

  describe "#call" do
    context "when circuit is closed" do
      it "executes the block successfully" do
        result = breaker.call { "success" }
        expect(result).to eq("success")
        expect(breaker).to be_closed
      end

      it "resets failure count on success" do
        # Cause one failure
        expect do
          breaker.call do
            raise StandardError
          end
        end.to raise_error(StandardError)
        expect(breaker.failure_count).to eq(1)

        # Successful call resets count
        breaker.call { "success" }
        expect(breaker.failure_count).to eq(0)
      end

      it "increments failure count on error" do
        expect do
          breaker.call do
            raise StandardError
          end
        end.to raise_error(StandardError)
        expect(breaker.failure_count).to eq(1)
      end

      it "opens circuit after threshold failures" do
        threshold.times do
          expect do
            breaker.call do
              raise StandardError
            end
          end.to raise_error(StandardError)
        end
        expect(breaker).to be_open
      end
    end

    context "when circuit is open" do
      before do
        threshold.times do
          expect do
            breaker.call do
              raise StandardError
            end
          end.to raise_error(StandardError)
        end
      end

      it "raises CircuitOpenError without executing block" do
        expect do
          breaker.call { "should not execute" }
        end.to raise_error(Fractor::Workflow::CircuitOpenError)
      end

      it "transitions to half-open after timeout" do
        # Manually set last_failure_time to past
        breaker.instance_variable_set(:@last_failure_time,
                                      Time.now - (timeout + 1))

        # Next call should transition to half-open
        expect do
          breaker.call do
            raise StandardError
          end
        end.to raise_error(StandardError)
        expect(breaker).to be_half_open
      end
    end

    context "when circuit is half-open" do
      before do
        # Open the circuit
        threshold.times do
          expect do
            breaker.call do
              raise StandardError
            end
          end.to raise_error(StandardError)
        end

        # Transition to half-open
        breaker.instance_variable_set(:@last_failure_time,
                                      Time.now - (timeout + 1))
        expect do
          breaker.call do
            raise StandardError
          end
        end.to raise_error(StandardError)
      end

      it "transitions to closed after successful half_open_calls" do
        half_open_calls.times do
          breaker.call { "success" }
        end
        expect(breaker).to be_closed
      end

      it "reopens circuit on any failure" do
        expect do
          breaker.call do
            raise StandardError
          end
        end.to raise_error(StandardError)
        expect(breaker).to be_open
      end
    end
  end

  describe "#stats" do
    it "returns circuit breaker statistics" do
      stats = breaker.stats
      expect(stats).to include(
        state: :closed,
        failure_count: 0,
        success_count: 0,
        threshold: threshold,
        timeout: timeout,
      )
    end

    it "updates stats after failures" do
      expect do
        breaker.call do
          raise StandardError
        end
      end.to raise_error(StandardError)
      stats = breaker.stats
      expect(stats[:failure_count]).to eq(1)
      expect(stats[:last_failure_time]).to be_a(Time)
    end
  end

  describe "#reset" do
    it "resets circuit to closed state" do
      # Open the circuit
      threshold.times do
        expect do
          breaker.call do
            raise StandardError
          end
        end.to raise_error(StandardError)
      end
      expect(breaker).to be_open

      # Reset
      breaker.reset
      expect(breaker).to be_closed
      expect(breaker.failure_count).to eq(0)
    end
  end

  describe "state transitions" do
    it "follows closed -> open -> half-open -> closed flow" do
      # Start closed
      expect(breaker).to be_closed

      # Move to open
      threshold.times do
        expect do
          breaker.call do
            raise StandardError
          end
        end.to raise_error(StandardError)
      end
      expect(breaker).to be_open

      # Move to half-open
      breaker.instance_variable_set(:@last_failure_time,
                                    Time.now - (timeout + 1))
      expect do
        breaker.call do
          raise StandardError
        end
      end.to raise_error(StandardError)
      expect(breaker).to be_half_open

      # Move to closed
      half_open_calls.times do
        breaker.call { "success" }
      end
      expect(breaker).to be_closed
    end

    it "follows closed -> open -> half-open -> open flow on failure" do
      # Start closed
      expect(breaker).to be_closed

      # Move to open
      threshold.times do
        expect do
          breaker.call do
            raise StandardError
          end
        end.to raise_error(StandardError)
      end
      expect(breaker).to be_open

      # Move to half-open
      breaker.instance_variable_set(:@last_failure_time,
                                    Time.now - (timeout + 1))
      expect do
        breaker.call do
          raise StandardError
        end
      end.to raise_error(StandardError)
      expect(breaker).to be_half_open

      # Fail and move back to open
      expect do
        breaker.call do
          raise StandardError
        end
      end.to raise_error(StandardError)
      expect(breaker).to be_open
    end
  end
end
