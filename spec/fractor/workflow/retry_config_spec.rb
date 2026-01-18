# frozen_string_literal: true

require "spec_helper"
require_relative "../../../lib/fractor/workflow/retry_config"

RSpec.describe Fractor::Workflow::RetryConfig do
  describe "#retryable?" do
    it "returns true for errors in retryable_errors list" do
      config = described_class.new(retryable_errors: [StandardError])
      expect(config.retryable?(StandardError.new)).to be true
    end

    it "returns true for subclasses of retryable errors" do
      config = described_class.new(retryable_errors: [StandardError])
      expect(config.retryable?(RuntimeError.new)).to be true
    end

    it "returns false for errors not in retryable_errors list" do
      config = described_class.new(retryable_errors: [ArgumentError])
      expect(config.retryable?(RuntimeError.new)).to be false
    end

    it "handles multiple retryable error types" do
      config = described_class.new(
        retryable_errors: [ArgumentError, IOError],
      )

      expect(config.retryable?(ArgumentError.new)).to be true
      expect(config.retryable?(IOError.new)).to be true
      expect(config.retryable?(RuntimeError.new)).to be false
    end
  end

  describe "#max_attempts" do
    it "delegates to strategy" do
      config = described_class.new(
        strategy: Fractor::Workflow::ExponentialBackoff.new(max_attempts: 5),
      )
      expect(config.max_attempts).to eq(5)
    end
  end

  describe "#delay_for" do
    it "delegates to strategy" do
      config = described_class.new(
        strategy: Fractor::Workflow::ConstantDelay.new(delay: 2),
      )
      expect(config.delay_for(2)).to eq(2)
    end
  end

  describe ".from_options" do
    it "creates exponential backoff strategy by default" do
      config = described_class.from_options(max_attempts: 3)
      expect(config.strategy).to be_a(Fractor::Workflow::ExponentialBackoff)
    end

    it "creates exponential backoff with custom options" do
      config = described_class.from_options(
        backoff: :exponential,
        max_attempts: 5,
        initial_delay: 2,
        max_delay: 10,
      )

      expect(config.strategy).to be_a(Fractor::Workflow::ExponentialBackoff)
      expect(config.strategy.initial_delay).to eq(2)
      expect(config.strategy.max_delay).to eq(10)
      expect(config.max_attempts).to eq(5)
    end

    it "creates linear backoff strategy" do
      config = described_class.from_options(
        backoff: :linear,
        max_attempts: 4,
        initial_delay: 1,
        increment: 0.5,
      )

      expect(config.strategy).to be_a(Fractor::Workflow::LinearBackoff)
      expect(config.strategy.initial_delay).to eq(1)
      expect(config.strategy.increment).to eq(0.5)
    end

    it "creates constant delay strategy" do
      config = described_class.from_options(
        backoff: :constant,
        max_attempts: 3,
        delay: 2,
      )

      expect(config.strategy).to be_a(Fractor::Workflow::ConstantDelay)
      expect(config.strategy.delay).to eq(2)
    end

    it "creates no retry strategy" do
      config = described_class.from_options(backoff: :none)
      expect(config.strategy).to be_a(Fractor::Workflow::NoRetry)
    end

    it "raises error for unknown backoff type" do
      expect do
        described_class.from_options(backoff: :unknown)
      end.to raise_error(ArgumentError, /Unknown backoff strategy/)
    end

    it "sets timeout" do
      config = described_class.from_options(timeout: 30)
      expect(config.timeout).to eq(30)
    end

    it "sets retryable_errors" do
      config = described_class.from_options(
        retryable_errors: [ArgumentError, IOError],
      )
      expect(config.retryable_errors).to eq([ArgumentError, IOError])
    end
  end
end

RSpec.describe Fractor::Workflow::RetryState do
  describe "#initialize" do
    it "starts with attempt 1" do
      state = described_class.new("test_job")
      expect(state.attempt).to eq(1)
    end

    it "stores job name" do
      state = described_class.new("my_job")
      expect(state.job_name).to eq("my_job")
    end

    it "starts with empty errors" do
      state = described_class.new("test_job")
      expect(state.errors).to be_empty
    end
  end

  describe "#record_failure" do
    it "records error and increments attempt" do
      state = described_class.new("test_job")
      error = StandardError.new("Test error")

      state.record_failure(error)

      expect(state.attempt).to eq(2)
      expect(state.errors.size).to eq(1)
      expect(state.errors.first[:error]).to eq(error)
      expect(state.errors.first[:attempt]).to eq(1)
    end

    it "records multiple failures" do
      state = described_class.new("test_job")

      3.times do |i|
        state.record_failure(StandardError.new("Error #{i}"))
      end

      expect(state.attempt).to eq(4)
      expect(state.errors.size).to eq(3)
    end
  end

  describe "#exhausted?" do
    it "returns false when attempts remain" do
      state = described_class.new("test_job")
      expect(state.exhausted?(3)).to be false

      state.record_failure(StandardError.new)
      expect(state.exhausted?(3)).to be false
    end

    it "returns true when attempts exhausted" do
      state = described_class.new("test_job")

      3.times { state.record_failure(StandardError.new) }
      expect(state.exhausted?(3)).to be true
    end
  end

  describe "#last_error" do
    it "returns nil when no errors" do
      state = described_class.new("test_job")
      expect(state.last_error).to be_nil
    end

    it "returns last error" do
      state = described_class.new("test_job")
      error1 = StandardError.new("Error 1")
      error2 = StandardError.new("Error 2")

      state.record_failure(error1)
      state.record_failure(error2)

      expect(state.last_error).to eq(error2)
    end
  end

  describe "#total_time" do
    it "returns elapsed time since start" do
      state = described_class.new("test_job")
      sleep 0.1
      expect(state.total_time).to be >= 0.1
    end
  end

  describe "#summary" do
    it "returns comprehensive summary" do
      state = described_class.new("test_job")
      error1 = StandardError.new("Error 1")
      error2 = RuntimeError.new("Error 2")

      state.record_failure(error1)
      state.record_failure(error2)

      summary = state.summary

      expect(summary[:job_name]).to eq("test_job")
      expect(summary[:total_attempts]).to eq(2)
      expect(summary[:total_time]).to be > 0
      expect(summary[:errors].size).to eq(2)

      expect(summary[:errors][0][:attempt]).to eq(1)
      expect(summary[:errors][0][:error_class]).to eq("StandardError")
      expect(summary[:errors][0][:error_message]).to eq("Error 1")

      expect(summary[:errors][1][:attempt]).to eq(2)
      expect(summary[:errors][1][:error_class]).to eq("RuntimeError")
      expect(summary[:errors][1][:error_message]).to eq("Error 2")
    end
  end
end
