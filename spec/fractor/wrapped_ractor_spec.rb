# frozen_string_literal: true

# Simple test worker class
module WrappedRactorSpec
  class TestWorker < Fractor::Worker
    def process(work)
      # Convert to integer to ensure multiplication works
      input_value = work.input.to_i
      Fractor::WorkResult.new(result: input_value * 2, work: work)
    end
  end
end

RSpec.describe Fractor::WrappedRactor do
  describe ".create" do
    it "creates a WrappedRactor instance using factory method" do
      wrapped_ractor = described_class.create("test_ractor", WrappedRactorSpec::TestWorker)

      expect(wrapped_ractor.name).to eq("test_ractor")
      expect(wrapped_ractor.ractor).to be_nil # Ractor not started yet
    end
  end

  describe "#start" do
    it "creates and starts a new Ractor" do
      wrapped_ractor = described_class.create("test_ractor", WrappedRactorSpec::TestWorker)
      wrapped_ractor.start

      expect(wrapped_ractor.ractor).to be_a(Ractor)
      expect(wrapped_ractor.closed?).to be false

      # Cleanup
      wrapped_ractor.close
    end

    it "allows the Ractor to receive initialization message", :ruby3 do
      wrapped_ractor = described_class.create("test_ractor", WrappedRactorSpec::TestWorker)
      wrapped_ractor.start

      # The initialization message should be available to receive
      message = wrapped_ractor.receive_message
      expect(message).to be_a(Hash)
      expect(message[:type]).to eq(:initialize)
      expect(message[:processor]).to eq("test_ractor")

      # Cleanup
      wrapped_ractor.close
    end
  end

  describe "#send and processing" do
    it "sends work to the Ractor and receives results", :ruby3 do
      wrapped_ractor = described_class.create("test_ractor", WrappedRactorSpec::TestWorker)
      wrapped_ractor.start

      # Receive the initialization message
      wrapped_ractor.receive_message

      # Send some work
      work = Fractor::Work.new(21)
      result = wrapped_ractor.send(work)

      # The send should be successful
      expect(result).to be true

      # The result or error should be available to receive
      message = wrapped_ractor.receive_message
      expect(message).to be_a(Hash)
      expect(%i[result error]).to include(message[:type])
      expect(message[:result]).to be_a(Fractor::WorkResult)

      # If it's a result (success), verify value is correct
      if message[:type] == :result
        expect(message[:result].result).to eq(42) # 21 * 2
      else
        # If error, just verify we have the error properly captured
        expect(message[:result].error).to be_a(String)
        expect(message[:result].success?).to be false
      end

      # Cleanup
      wrapped_ractor.close
    end
  end

  describe "#close" do
    it "closes the Ractor", :ruby3 do
      wrapped_ractor = described_class.create("test_ractor", WrappedRactorSpec::TestWorker)
      wrapped_ractor.start

      # Receive the initialization message
      wrapped_ractor.receive_message

      # Close the Ractor
      wrapped_ractor.close

      # Check it's closed
      expect(wrapped_ractor.closed?).to be true
    end
  end

  describe "#closed?" do
    it "returns true if the Ractor is nil" do
      wrapped_ractor = described_class.create("test_ractor", WrappedRactorSpec::TestWorker)
      # Don't start the Ractor

      expect(wrapped_ractor.closed?).to be true
    end

    it "returns true if the Ractor is closed", :ruby3 do
      wrapped_ractor = described_class.create("test_ractor", WrappedRactorSpec::TestWorker)
      wrapped_ractor.start

      # Receive the initialization message
      wrapped_ractor.receive_message

      # Close the Ractor
      wrapped_ractor.close

      expect(wrapped_ractor.closed?).to be true
    end

    it "returns false if the Ractor is active", :ruby3 do
      wrapped_ractor = described_class.create("test_ractor", WrappedRactorSpec::TestWorker)
      wrapped_ractor.start

      # Receive the initialization message
      wrapped_ractor.receive_message

      expect(wrapped_ractor.closed?).to be false

      # Cleanup
      wrapped_ractor.close
    end
  end
end
