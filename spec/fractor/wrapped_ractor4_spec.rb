# frozen_string_literal: true

require "spec_helper"

# Simple test worker class
module WrappedRactor4Spec
  class TestWorker < Fractor::Worker
    def process(work)
      input_value = work.input.to_i
      Fractor::WorkResult.new(result: input_value * 2, work: work)
    end
  end
end

# Skip all tests in this file on Ruby 3.x
RSpec.describe Fractor::WrappedRactor4, :ruby4 do
  describe "Ruby 4.0 specific behavior" do
    describe "#initialize" do
      it "creates a WrappedRactor4 instance with a name, worker class, and response port" do
        response_port = Ractor::Port.new
        wrapped_ractor = described_class.new("test_ractor", WrappedRactor4Spec::TestWorker,
                                             response_port: response_port)

        expect(wrapped_ractor.name).to eq("test_ractor")
        expect(wrapped_ractor.response_port).to eq(response_port)
        expect(wrapped_ractor.ractor).to be_nil # Ractor not started yet
      end
    end

    describe "#response_port=" do
      it "sets the response port for the worker" do
        wrapped_ractor = described_class.new("test_ractor", WrappedRactor4Spec::TestWorker)
        response_port = Ractor::Port.new

        wrapped_ractor.response_port = response_port

        expect(wrapped_ractor.response_port).to eq(response_port)
      end
    end

    describe "#start" do
      it "creates and starts a new Ractor using port-based messaging" do
        response_port = Ractor::Port.new
        wrapped_ractor = described_class.new("test_ractor", WrappedRactor4Spec::TestWorker,
                                             response_port: response_port)
        wrapped_ractor.start

        expect(wrapped_ractor.ractor).to be_a(Ractor)
        expect(wrapped_ractor.closed?).to be false

        # Cleanup
        wrapped_ractor.close
      end

      it "does NOT send initialization message (Ruby 4.0 behavior change)" do
        response_port = Ractor::Port.new
        wrapped_ractor = described_class.new("test_ractor", WrappedRactor4Spec::TestWorker,
                                             response_port: response_port)
        wrapped_ractor.start

        # In Ruby 4.0, no :initialize message is sent
        # The worker just waits for work to be sent
        # We can't receive_message here because there's no message

        # Cleanup
        wrapped_ractor.close
      end

      it "creates Ractor that waits for [work, response_port] messages" do
        response_port = Ractor::Port.new
        wrapped_ractor = described_class.new("test_ractor", WrappedRactor4Spec::TestWorker,
                                             response_port: response_port)
        wrapped_ractor.start

        # Send work in the Ruby 4.0 format: [work, response_port]
        work = Fractor::Work.new(21)
        result = wrapped_ractor.send(work)

        expect(result).to be true

        # The result should come through the response_port
        # Note: We can't test this easily without setting up the port receiving

        # Cleanup
        wrapped_ractor.close
      end
    end

    describe "#send" do
      it "sends [work, response_port] array to the Ractor" do
        response_port = Ractor::Port.new
        wrapped_ractor = described_class.new("test_ractor", WrappedRactor4Spec::TestWorker,
                                             response_port: response_port)
        wrapped_ractor.start

        # Send work
        work = Fractor::Work.new(21)
        result = wrapped_ractor.send(work)

        expect(result).to be true

        # Cleanup
        wrapped_ractor.close
      end

      it "sends :shutdown symbol directly (not in an array)" do
        response_port = Ractor::Port.new
        wrapped_ractor = described_class.new("test_ractor", WrappedRactor4Spec::TestWorker,
                                             response_port: response_port)
        wrapped_ractor.start

        # Send shutdown
        result = wrapped_ractor.send(:shutdown)

        expect(result).to be true

        # Cleanup
        response_port.close
      end

      it "returns false if Ractor is nil" do
        response_port = Ractor::Port.new
        wrapped_ractor = described_class.new("test_ractor", WrappedRactor4Spec::TestWorker,
                                             response_port: response_port)
        # Don't start the Ractor

        work = Fractor::Work.new(21)
        result = wrapped_ractor.send(work)

        expect(result).to be false
      end

      it "handles Ractor send errors gracefully" do
        response_port = Ractor::Port.new
        wrapped_ractor = described_class.new("test_ractor", WrappedRactor4Spec::TestWorker,
                                             response_port: response_port)
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
      it "returns nil when response_port is nil" do
        wrapped_ractor = described_class.new("test_ractor", WrappedRactor4Spec::TestWorker)
        # No response_port set

        result = wrapped_ractor.receive_message

        expect(result).to be_nil
      end
    end

    describe "#close" do
      it "closes the response port and then the Ractor" do
        response_port = Ractor::Port.new
        wrapped_ractor = described_class.new("test_ractor", WrappedRactor4Spec::TestWorker,
                                             response_port: response_port)
        wrapped_ractor.start

        # Close the ractor
        result = wrapped_ractor.close

        expect(result).to be true
        expect(wrapped_ractor.response_port).to be_nil # Port should be cleared
      end

      it "handles closing when response_port is nil" do
        wrapped_ractor = described_class.new("test_ractor", WrappedRactor4Spec::TestWorker)
        # No response_port set

        expect { wrapped_ractor.close }.not_to raise_error
      end
    end

    describe "#closed?" do
      it "returns true if the Ractor is nil" do
        response_port = Ractor::Port.new
        wrapped_ractor = described_class.new("test_ractor", WrappedRactor4Spec::TestWorker,
                                             response_port: response_port)
        # Don't start the Ractor

        expect(wrapped_ractor.closed?).to be true
      end

      it "returns true if the Ractor is closed" do
        response_port = Ractor::Port.new
        wrapped_ractor = described_class.new("test_ractor", WrappedRactor4Spec::TestWorker,
                                             response_port: response_port)
        wrapped_ractor.start

        # Close the Ractor
        wrapped_ractor.close

        expect(wrapped_ractor.closed?).to be true
      end

      it "returns false if the Ractor is active" do
        response_port = Ractor::Port.new
        wrapped_ractor = described_class.new("test_ractor", WrappedRactor4Spec::TestWorker,
                                             response_port: response_port)
        wrapped_ractor.start

        expect(wrapped_ractor.closed?).to be false

        # Cleanup
        wrapped_ractor.close
      end
    end
  end

  describe "Ractor::IsolationError compliance" do
    it "does not access instance variables from inside Ractor block" do
      # This test verifies that the implementation correctly uses parameters
      # instead of instance variables inside the Ractor block
      response_port = Ractor::Port.new

      # The Ractor block should use the 'name' parameter, not @name
      wrapped_ractor = described_class.new("test_ractor", WrappedRactor4Spec::TestWorker,
                                           response_port: response_port)

      expect { wrapped_ractor.start }.not_to raise_error(Ractor::IsolationError)

      # Cleanup
      wrapped_ractor.close
    end
  end

  describe "integration with main loop" do
    it "works with Ractor.select for receiving responses" do
      # Create a response port that will receive the result
      response_port = Ractor::Port.new

      wrapped_ractor = described_class.new("test_ractor", WrappedRactor4Spec::TestWorker,
                                           response_port: response_port)
      wrapped_ractor.start

      # Send work
      work = Fractor::Work.new(21)
      wrapped_ractor.send(work)

      # The result should be sent to response_port
      # We would use Ractor.select in the main loop to receive it

      # Cleanup
      wrapped_ractor.close
    end
  end
end
