# frozen_string_literal: true

require "spec_helper"

# Simple test worker class
module WrappedRactor3Spec
  class TestWorker < Fractor::Worker
    def process(work)
      input_value = work.input.to_i
      Fractor::WorkResult.new(result: input_value * 2, work: work)
    end
  end
end

# Skip all tests in this file on Ruby 4.0+
RSpec.describe Fractor::WrappedRactor3, :ruby3 do
  describe "Ruby 3.x specific behavior" do
    describe "#initialize" do
      it "creates a WrappedRactor3 instance with a name and worker class" do
        wrapped_ractor = described_class.new("test_ractor", WrappedRactor3Spec::TestWorker)

        expect(wrapped_ractor.name).to eq("test_ractor")
        expect(wrapped_ractor.ractor).to be_nil # Ractor not started yet
      end
    end

    describe "#start" do
      it "creates and starts a new Ractor using yield-based messaging" do
        wrapped_ractor = described_class.new("test_ractor", WrappedRactor3Spec::TestWorker)
        wrapped_ractor.start

        expect(wrapped_ractor.ractor).to be_a(Ractor)
        expect(wrapped_ractor.closed?).to be false

        # Cleanup
        wrapped_ractor.close
      end

      it "sends initialization message that can be received" do
        wrapped_ractor = described_class.new("test_ractor", WrappedRactor3Spec::TestWorker)
        wrapped_ractor.start

        # Ruby 3.x sends an :initialize message on startup
        message = wrapped_ractor.receive_message
        expect(message).to be_a(Hash)
        expect(message[:type]).to eq(:initialize)
        expect(message[:processor]).to eq("test_ractor")

        # Cleanup
        wrapped_ractor.close
      end

      it "captures Ractor creation errors" do
        # Use an invalid worker class that will fail to instantiate
        invalid_worker = Class.new(Fractor::Worker) do
          def initialize(*_args)
            raise "Intentional initialization error"
          end

          def process(work)
            Fractor::WorkResult.new(result: nil, work: work)
          end
        end

        wrapped_ractor = described_class.new("test_ractor", invalid_worker)

        # Should handle the error gracefully
        expect { wrapped_ractor.start }.not_to raise_error
      end
    end

    describe "#send" do
      it "sends work to the Ractor using Ractor.send" do
        wrapped_ractor = described_class.new("test_ractor", WrappedRactor3Spec::TestWorker)
        wrapped_ractor.start

        # Receive the initialization message
        wrapped_ractor.receive_message

        # Send some work
        work = Fractor::Work.new(21)
        result = wrapped_ractor.send(work)

        expect(result).to be true

        # Cleanup
        wrapped_ractor.close
      end

      it "returns false if Ractor is nil" do
        wrapped_ractor = described_class.new("test_ractor", WrappedRactor3Spec::TestWorker)
        # Don't start the Ractor

        work = Fractor::Work.new(21)
        result = wrapped_ractor.send(work)

        expect(result).to be false
      end

      it "handles Ractor send errors gracefully" do
        wrapped_ractor = described_class.new("test_ractor", WrappedRactor3Spec::TestWorker)
        wrapped_ractor.start

        # Close the ractor first
        wrapped_ractor.close

        # Try to send work to a closed ractor
        work = Fractor::Work.new(21)
        result = wrapped_ractor.send(work)

        expect(result).to be false
      end
    end

    describe "#receive_message" do
      it "receives initialization message from Ractor" do
        wrapped_ractor = described_class.new("test_ractor", WrappedRactor3Spec::TestWorker)
        wrapped_ractor.start

        message = wrapped_ractor.receive_message

        expect(message).to be_a(Hash)
        expect(message[:type]).to eq(:initialize)

        # Cleanup
        wrapped_ractor.close
      end

      it "receives result messages from Ractor after sending work" do
        wrapped_ractor = described_class.new("test_ractor", WrappedRactor3Spec::TestWorker)
        wrapped_ractor.start

        # Receive initialization
        wrapped_ractor.receive_message

        # Send work
        work = Fractor::Work.new(21)
        wrapped_ractor.send(work)

        # Receive result
        message = wrapped_ractor.receive_message

        expect(message).to be_a(Hash)
        expect(message[:type]).to eq(:result)
        expect(message[:result]).to be_a(Fractor::WorkResult)
        expect(message[:result].result).to eq(42) # 21 * 2

        # Cleanup
        wrapped_ractor.close
      end

      it "receives error messages when work processing fails" do
        error_worker = Class.new(Fractor::Worker) do
          def process(_work)
            raise "Intentional processing error"
          end
        end

        wrapped_ractor = described_class.new("test_ractor", error_worker)
        wrapped_ractor.start

        # Receive initialization
        wrapped_ractor.receive_message

        # Send work that will fail
        work = Fractor::Work.new(21)
        wrapped_ractor.send(work)

        # Receive error result
        message = wrapped_ractor.receive_message

        expect(message).to be_a(Hash)
        expect(message[:type]).to eq(:error)
        expect(message[:result]).to be_a(Fractor::WorkResult)
        expect(message[:result].success?).to be false
        expect(message[:result].error).to include("Intentional processing error")

        # Cleanup
        wrapped_ractor.close
      end

      it "has receive_message method available" do
        wrapped_ractor = described_class.new("test_ractor", WrappedRactor3Spec::TestWorker)
        wrapped_ractor.start

        # Just verify the method exists, don't call it when no message available
        expect(wrapped_ractor).to respond_to(:receive_message)

        # Cleanup
        wrapped_ractor.close
      end
    end

    describe "#close" do
      it "closes the Ractor by sending shutdown message" do
        wrapped_ractor = described_class.new("test_ractor", WrappedRactor3Spec::TestWorker)
        wrapped_ractor.start

        # Receive initialization
        wrapped_ractor.receive_message

        # Close the ractor
        result = wrapped_ractor.close

        expect(result).to be true
        expect(wrapped_ractor.closed?).to be true
      end

      it "returns true if Ractor is already nil" do
        wrapped_ractor = described_class.new("test_ractor", WrappedRactor3Spec::TestWorker)
        # Don't start the Ractor

        result = wrapped_ractor.close

        expect(result).to be true
      end

      it "returns true if Ractor is already closed" do
        wrapped_ractor = described_class.new("test_ractor", WrappedRactor3Spec::TestWorker)
        wrapped_ractor.start

        # Receive initialization
        wrapped_ractor.receive_message

        # Close once
        wrapped_ractor.close

        # Close again
        result = wrapped_ractor.close

        expect(result).to be true
      end
    end

    describe "#closed?" do
      it "returns true if the Ractor is nil" do
        wrapped_ractor = described_class.new("test_ractor", WrappedRactor3Spec::TestWorker)
        # Don't start the Ractor

        expect(wrapped_ractor.closed?).to be true
      end

      it "returns true if the Ractor is closed" do
        wrapped_ractor = described_class.new("test_ractor", WrappedRactor3Spec::TestWorker)
        wrapped_ractor.start

        # Receive initialization
        wrapped_ractor.receive_message

        # Close the Ractor
        wrapped_ractor.close

        expect(wrapped_ractor.closed?).to be true
      end

      it "returns false if the Ractor is active" do
        wrapped_ractor = described_class.new("test_ractor", WrappedRactor3Spec::TestWorker)
        wrapped_ractor.start

        # Receive initialization
        wrapped_ractor.receive_message

        expect(wrapped_ractor.closed?).to be false

        # Cleanup
        wrapped_ractor.close
      end
    end
  end

  describe "integration tests" do
    it "processes multiple work items sequentially" do
      wrapped_ractor = described_class.new("test_ractor", WrappedRactor3Spec::TestWorker)
      wrapped_ractor.start

      # Receive initialization
      wrapped_ractor.receive_message

      # Send multiple work items
      results = []
      5.times do |i|
        work = Fractor::Work.new(i + 1)
        wrapped_ractor.send(work)

        # Receive result
        message = wrapped_ractor.receive_message
        results << message[:result].result
      end

      expect(results).to eq([2, 4, 6, 8, 10]) # Each value doubled

      # Cleanup
      wrapped_ractor.close
    end

    it "handles mix of successful and failed work items" do
      mixed_worker = Class.new(Fractor::Worker) do
        def process(work)
          value = work.input.to_i
          if value.even?
            Fractor::WorkResult.new(result: value * 2, work: work)
          else
            raise "Odd numbers not allowed"
          end
        end
      end

      wrapped_ractor = described_class.new("test_ractor", mixed_worker)
      wrapped_ractor.start

      # Receive initialization
      wrapped_ractor.receive_message

      # Send work items
      successes = 0
      errors = 0

      4.times do |i|
        work = Fractor::Work.new(i + 1) # 1, 2, 3, 4
        wrapped_ractor.send(work)

        message = wrapped_ractor.receive_message
        if message[:type] == :result
          successes += 1
        else
          errors += 1
        end
      end

      expect(successes).to eq(2) # 2 and 4 succeed
      expect(errors).to eq(2) # 1 and 3 fail

      # Cleanup
      wrapped_ractor.close
    end
  end
end
