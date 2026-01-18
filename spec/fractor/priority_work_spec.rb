# frozen_string_literal: true

require "spec_helper"

RSpec.describe Fractor::PriorityWork do
  describe "#initialize" do
    it "creates work with default normal priority" do
      work = described_class.new("test data")
      expect(work.input).to eq("test data")
      expect(work.priority).to eq(:normal)
    end

    it "creates work with specified priority" do
      work = described_class.new("urgent", priority: :critical)
      expect(work.priority).to eq(:critical)
    end

    it "raises error for invalid priority" do
      expect do
        described_class.new("test", priority: :invalid)
      end.to raise_error(ArgumentError, /Invalid priority/)
    end

    it "sets created_at timestamp" do
      work = described_class.new("test")
      expect(work.created_at).to be_a(Time)
      expect(work.created_at).to be <= Time.now
    end
  end

  describe "#priority_value" do
    it "returns correct numeric value for critical" do
      work = described_class.new("test", priority: :critical)
      expect(work.priority_value).to eq(0)
    end

    it "returns correct numeric value for high" do
      work = described_class.new("test", priority: :high)
      expect(work.priority_value).to eq(1)
    end

    it "returns correct numeric value for normal" do
      work = described_class.new("test", priority: :normal)
      expect(work.priority_value).to eq(2)
    end

    it "returns correct numeric value for low" do
      work = described_class.new("test", priority: :low)
      expect(work.priority_value).to eq(3)
    end

    it "returns correct numeric value for background" do
      work = described_class.new("test", priority: :background)
      expect(work.priority_value).to eq(4)
    end
  end

  describe "#age" do
    it "returns age in seconds" do
      work = described_class.new("test")
      sleep 0.1
      expect(work.age).to be >= 0.1
      expect(work.age).to be < 1.0
    end

    it "increases over time" do
      work = described_class.new("test")
      age1 = work.age
      sleep 0.05
      age2 = work.age
      expect(age2).to be > age1
    end
  end

  describe "#<=>" do
    it "orders by priority value (lower value = higher priority)" do
      critical = described_class.new("c", priority: :critical)
      high = described_class.new("h", priority: :high)
      normal = described_class.new("n", priority: :normal)
      low = described_class.new("l", priority: :low)
      background = described_class.new("b", priority: :background)

      expect(critical <=> high).to eq(-1)
      expect(high <=> normal).to eq(-1)
      expect(normal <=> low).to eq(-1)
      expect(low <=> background).to eq(-1)
    end

    it "uses FIFO for same priority (older first)" do
      work1 = described_class.new("first", priority: :normal)
      sleep 0.01
      work2 = described_class.new("second", priority: :normal)

      expect(work1 <=> work2).to eq(-1)
      expect(work2 <=> work1).to eq(1)
    end

    it "returns nil when comparing with non-PriorityWork" do
      work = described_class.new("test")
      expect(work <=> "string").to be_nil
    end

    it "returns 0 for same work" do
      work = described_class.new("test")
      expect(work <=> work).to eq(0)
    end
  end

  describe "#higher_priority_than?" do
    it "returns true when this work has higher priority" do
      critical = described_class.new("c", priority: :critical)
      normal = described_class.new("n", priority: :normal)

      expect(critical.higher_priority_than?(normal)).to be true
    end

    it "returns false when this work has lower priority" do
      low = described_class.new("l", priority: :low)
      high = described_class.new("h", priority: :high)

      expect(low.higher_priority_than?(high)).to be false
    end

    it "returns false for same priority" do
      work1 = described_class.new("1", priority: :normal)
      work2 = described_class.new("2", priority: :normal)

      expect(work1.higher_priority_than?(work2)).to be false
    end

    it "returns false when comparing with non-PriorityWork" do
      work = described_class.new("test")
      expect(work.higher_priority_than?("string")).to be false
    end
  end

  describe "sorting" do
    it "sorts array of work items correctly" do
      low = described_class.new("low", priority: :low)
      critical = described_class.new("critical", priority: :critical)
      normal = described_class.new("normal", priority: :normal)
      high = described_class.new("high", priority: :high)

      sorted = [low, critical, normal, high].sort
      expect(sorted.map(&:input)).to eq(["critical", "high", "normal", "low"])
    end

    it "maintains FIFO within same priority" do
      work1 = described_class.new("first", priority: :normal)
      sleep 0.01
      work2 = described_class.new("second", priority: :normal)
      sleep 0.01
      work3 = described_class.new("third", priority: :normal)

      sorted = [work3, work1, work2].sort
      expect(sorted.map(&:input)).to eq(["first", "second", "third"])
    end
  end

  describe "integration with base Work class" do
    it "inherits from Work" do
      work = described_class.new("test")
      expect(work).to be_a(Fractor::Work)
    end

    it "maintains Work functionality" do
      work = described_class.new({ key: "value" })
      expect(work.input).to eq({ key: "value" })
    end
  end
end
