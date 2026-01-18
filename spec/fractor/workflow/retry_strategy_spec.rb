# frozen_string_literal: true

require "spec_helper"
require_relative "../../../lib/fractor/workflow/retry_strategy"

RSpec.describe Fractor::Workflow::RetryStrategy do
  describe "base class" do
    it "cannot be instantiated directly" do
      strategy = described_class.new(max_attempts: 3)
      expect { strategy.delay_for(1) }.to raise_error(NotImplementedError)
    end

    it "stores max_attempts" do
      strategy = described_class.new(max_attempts: 5)
      expect(strategy.max_attempts).to eq(5)
    end

    it "stores max_delay" do
      strategy = described_class.new(max_attempts: 3, max_delay: 10)
      expect(strategy.max_delay).to eq(10)
    end
  end
end

RSpec.describe Fractor::Workflow::ExponentialBackoff do
  describe "#delay_for" do
    it "returns 0 for first attempt" do
      strategy = described_class.new(initial_delay: 1)
      expect(strategy.delay_for(1)).to eq(0)
    end

    it "calculates exponential delays" do
      strategy = described_class.new(initial_delay: 1, multiplier: 2)

      expect(strategy.delay_for(2)).to eq(1)   # 1 * 2^0
      expect(strategy.delay_for(3)).to eq(2)   # 1 * 2^1
      expect(strategy.delay_for(4)).to eq(4)   # 1 * 2^2
      expect(strategy.delay_for(5)).to eq(8)   # 1 * 2^3
    end

    it "respects custom multiplier" do
      strategy = described_class.new(initial_delay: 1, multiplier: 3)

      expect(strategy.delay_for(2)).to eq(1)   # 1 * 3^0
      expect(strategy.delay_for(3)).to eq(3)   # 1 * 3^1
      expect(strategy.delay_for(4)).to eq(9)   # 1 * 3^2
    end

    it "caps delay at max_delay" do
      strategy = described_class.new(
        initial_delay: 1,
        multiplier: 2,
        max_delay: 5,
      )

      expect(strategy.delay_for(2)).to eq(1)
      expect(strategy.delay_for(3)).to eq(2)
      expect(strategy.delay_for(4)).to eq(4)
      expect(strategy.delay_for(5)).to eq(5)  # Capped
      expect(strategy.delay_for(6)).to eq(5)  # Still capped
    end
  end
end

RSpec.describe Fractor::Workflow::LinearBackoff do
  describe "#delay_for" do
    it "returns 0 for first attempt" do
      strategy = described_class.new(initial_delay: 1)
      expect(strategy.delay_for(1)).to eq(0)
    end

    it "calculates linear delays" do
      strategy = described_class.new(initial_delay: 1, increment: 0.5)

      expect(strategy.delay_for(2)).to eq(1)     # 1 + 0.5 * 0
      expect(strategy.delay_for(3)).to eq(1.5)   # 1 + 0.5 * 1
      expect(strategy.delay_for(4)).to eq(2)     # 1 + 0.5 * 2
      expect(strategy.delay_for(5)).to eq(2.5)   # 1 + 0.5 * 3
    end

    it "respects custom increment" do
      strategy = described_class.new(initial_delay: 2, increment: 1)

      expect(strategy.delay_for(2)).to eq(2)
      expect(strategy.delay_for(3)).to eq(3)
      expect(strategy.delay_for(4)).to eq(4)
    end

    it "caps delay at max_delay" do
      strategy = described_class.new(
        initial_delay: 1,
        increment: 1,
        max_delay: 3,
      )

      expect(strategy.delay_for(2)).to eq(1)
      expect(strategy.delay_for(3)).to eq(2)
      expect(strategy.delay_for(4)).to eq(3)  # Capped
      expect(strategy.delay_for(5)).to eq(3)  # Still capped
    end
  end
end

RSpec.describe Fractor::Workflow::ConstantDelay do
  describe "#delay_for" do
    it "returns 0 for first attempt" do
      strategy = described_class.new(delay: 2)
      expect(strategy.delay_for(1)).to eq(0)
    end

    it "returns constant delay for all attempts" do
      strategy = described_class.new(delay: 2)

      expect(strategy.delay_for(2)).to eq(2)
      expect(strategy.delay_for(3)).to eq(2)
      expect(strategy.delay_for(4)).to eq(2)
      expect(strategy.delay_for(100)).to eq(2)
    end

    it "caps delay at max_delay" do
      strategy = described_class.new(delay: 5, max_delay: 3)

      expect(strategy.delay_for(2)).to eq(3)
      expect(strategy.delay_for(3)).to eq(3)
    end
  end
end

RSpec.describe Fractor::Workflow::NoRetry do
  describe "#delay_for" do
    it "always returns 0" do
      strategy = described_class.new

      expect(strategy.delay_for(1)).to eq(0)
      expect(strategy.delay_for(2)).to eq(0)
    end
  end

  describe "#max_attempts" do
    it "is always 1" do
      strategy = described_class.new
      expect(strategy.max_attempts).to eq(1)
    end
  end
end
