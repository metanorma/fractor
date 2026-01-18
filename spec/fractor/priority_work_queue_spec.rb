# frozen_string_literal: true

require "spec_helper"

RSpec.describe Fractor::PriorityWorkQueue do
  let(:queue) { described_class.new }

  describe "#initialize" do
    it "creates empty queue by default" do
      expect(queue).to be_empty
      expect(queue.size).to eq(0)
    end

    it "accepts aging configuration" do
      aged_queue = described_class.new(aging_enabled: true, aging_threshold: 30)
      expect(aged_queue.aging_enabled).to be true
      expect(aged_queue.aging_threshold).to eq(30)
    end

    it "disables aging by default" do
      expect(queue.aging_enabled).to be false
    end
  end

  describe "#push" do
    it "adds work to queue" do
      work = Fractor::PriorityWork.new("test", priority: :normal)
      queue.push(work)
      expect(queue.size).to eq(1)
    end

    it "raises error for non-PriorityWork" do
      expect do
        queue.push("not a PriorityWork")
      end.to raise_error(ArgumentError, /Work must be a PriorityWork/)
    end

    it "raises error when queue is closed" do
      queue.close
      work = Fractor::PriorityWork.new("test")
      expect do
        queue.push(work)
      end.to raise_error(Fractor::ClosedQueueError, /Queue is closed/)
    end

    it "maintains priority order" do
      low = Fractor::PriorityWork.new("low", priority: :low)
      critical = Fractor::PriorityWork.new("critical", priority: :critical)
      normal = Fractor::PriorityWork.new("normal", priority: :normal)

      queue.push(low)
      queue.push(critical)
      queue.push(normal)

      expect(queue.pop.input).to eq("critical")
      expect(queue.pop.input).to eq("normal")
      expect(queue.pop.input).to eq("low")
    end
  end

  describe "#pop" do
    it "returns highest priority work" do
      normal = Fractor::PriorityWork.new("normal", priority: :normal)
      high = Fractor::PriorityWork.new("high", priority: :high)

      queue.push(normal)
      queue.push(high)

      expect(queue.pop.input).to eq("high")
    end

    it "maintains FIFO within same priority" do
      work1 = Fractor::PriorityWork.new("first", priority: :normal)
      sleep 0.01
      work2 = Fractor::PriorityWork.new("second", priority: :normal)
      sleep 0.01
      work3 = Fractor::PriorityWork.new("third", priority: :normal)

      queue.push(work1)
      queue.push(work2)
      queue.push(work3)

      expect(queue.pop.input).to eq("first")
      expect(queue.pop.input).to eq("second")
      expect(queue.pop.input).to eq("third")
    end

    it "returns nil when queue is closed and empty" do
      queue.close
      expect(queue.pop).to be_nil
    end

    it "blocks when queue is empty" do
      result = nil
      thread = Thread.new { result = queue.pop }

      sleep 0.1
      expect(thread.alive?).to be true

      queue.push(Fractor::PriorityWork.new("test"))
      thread.join

      expect(result.input).to eq("test")
    end
  end

  describe "#pop_non_blocking" do
    it "returns work immediately if available" do
      work = Fractor::PriorityWork.new("test")
      queue.push(work)

      expect(queue.pop_non_blocking.input).to eq("test")
    end

    it "returns nil immediately if queue is empty" do
      expect(queue.pop_non_blocking).to be_nil
    end

    it "respects priority ordering" do
      low = Fractor::PriorityWork.new("low", priority: :low)
      critical = Fractor::PriorityWork.new("critical", priority: :critical)

      queue.push(low)
      queue.push(critical)

      expect(queue.pop_non_blocking.input).to eq("critical")
    end
  end

  describe "#size and #length" do
    it "returns 0 for empty queue" do
      expect(queue.size).to eq(0)
      expect(queue.length).to eq(0)
    end

    it "returns correct count" do
      3.times { |i| queue.push(Fractor::PriorityWork.new(i)) }
      expect(queue.size).to eq(3)
      expect(queue.length).to eq(3)
    end

    it "decreases after pop" do
      queue.push(Fractor::PriorityWork.new("test"))
      expect(queue.size).to eq(1)
      queue.pop
      expect(queue.size).to eq(0)
    end
  end

  describe "#empty?" do
    it "returns true for new queue" do
      expect(queue).to be_empty
    end

    it "returns false when queue has items" do
      queue.push(Fractor::PriorityWork.new("test"))
      expect(queue).not_to be_empty
    end

    it "returns true after popping all items" do
      queue.push(Fractor::PriorityWork.new("test"))
      queue.pop
      expect(queue).to be_empty
    end
  end

  describe "#close" do
    it "marks queue as closed" do
      expect(queue).not_to be_closed
      queue.close
      expect(queue).to be_closed
    end

    it "wakes up waiting threads" do
      thread = Thread.new { queue.pop }
      sleep 0.1

      queue.close
      thread.join(1)

      expect(thread.alive?).to be false
    end

    it "prevents new pushes" do
      queue.close
      expect do
        queue.push(Fractor::PriorityWork.new("test"))
      end.to raise_error(Fractor::ClosedQueueError)
    end

    it "allows existing items to be popped" do
      queue.push(Fractor::PriorityWork.new("test"))
      queue.close

      expect(queue.pop.input).to eq("test")
    end
  end

  describe "#clear" do
    it "removes all items" do
      5.times { |i| queue.push(Fractor::PriorityWork.new(i)) }
      expect(queue.size).to eq(5)

      queue.clear
      expect(queue).to be_empty
    end

    it "returns removed items" do
      work1 = Fractor::PriorityWork.new("first")
      work2 = Fractor::PriorityWork.new("second")

      queue.push(work1)
      queue.push(work2)

      cleared = queue.clear
      expect(cleared.size).to eq(2)
      expect(cleared).to include(work1, work2)
    end
  end

  describe "#stats" do
    it "returns statistics for empty queue" do
      stats = queue.stats
      expect(stats[:total]).to eq(0)
      expect(stats[:by_priority]).to be_empty
      expect(stats[:oldest_age]).to eq(0)
      expect(stats[:closed]).to be false
    end

    it "counts items by priority" do
      queue.push(Fractor::PriorityWork.new("c1", priority: :critical))
      queue.push(Fractor::PriorityWork.new("c2", priority: :critical))
      queue.push(Fractor::PriorityWork.new("n1", priority: :normal))

      stats = queue.stats
      expect(stats[:total]).to eq(3)
      expect(stats[:by_priority][:critical]).to eq(2)
      expect(stats[:by_priority][:normal]).to eq(1)
    end

    it "tracks oldest work age" do
      queue.push(Fractor::PriorityWork.new("old"))
      sleep 0.1

      stats = queue.stats
      expect(stats[:oldest_age]).to be >= 0.1
    end

    it "reflects closed status" do
      stats = queue.stats
      expect(stats[:closed]).to be false

      queue.close
      stats = queue.stats
      expect(stats[:closed]).to be true
    end
  end

  describe "priority aging" do
    let(:aged_queue) do
      described_class.new(aging_enabled: true, aging_threshold: 0.1)
    end

    it "boosts priority of old low-priority work" do
      low = Fractor::PriorityWork.new("low", priority: :low)
      aged_queue.push(low)

      sleep 0.25 # Wait longer for more aging effect

      normal = Fractor::PriorityWork.new("normal", priority: :normal)
      aged_queue.push(normal)

      # The low priority work should be boosted due to aging
      # After 0.25s with 0.1s threshold, low gets 2 levels boost (from 3 to 1)
      # making it higher priority than normal (2)
      first = aged_queue.pop_non_blocking
      expect(first.input).to eq("low")
    end

    it "does not boost critical priority work" do
      critical = Fractor::PriorityWork.new("critical", priority: :critical)
      aged_queue.push(critical)

      sleep 0.15

      # Critical priority can't be boosted further
      expect(aged_queue.pop_non_blocking.input).to eq("critical")
    end
  end

  describe "thread safety" do
    it "handles concurrent pushes" do
      threads = Array.new(10) do |i|
        Thread.new do
          queue.push(Fractor::PriorityWork.new(i))
        end
      end

      threads.each(&:join)
      expect(queue.size).to eq(10)
    end

    it "handles concurrent pops" do
      10.times { |i| queue.push(Fractor::PriorityWork.new(i)) }

      results = []
      mutex = Mutex.new

      threads = Array.new(10) do
        Thread.new do
          work = queue.pop
          mutex.synchronize { results << work.input }
        end
      end

      threads.each(&:join)
      expect(results.size).to eq(10)
    end

    it "handles mixed concurrent operations" do
      producers = Array.new(5) do |i|
        Thread.new do
          5.times do |j|
            queue.push(Fractor::PriorityWork.new("p#{i}-#{j}"))
            sleep 0.001
          end
        end
      end

      consumers = Array.new(3) do
        Thread.new do
          items = []
          8.times { items << queue.pop }
          items
        end
      end

      producers.each(&:join)
      consumer_results = consumers.map(&:value).flatten

      expect(consumer_results.size).to eq(24)
      expect(queue.size).to eq(1) # 25 produced - 24 consumed
    end
  end

  describe "aliases" do
    it "supports << alias for push" do
      work = Fractor::PriorityWork.new("test")
      queue << work
      expect(queue.size).to eq(1)
    end

    it "supports enqueue alias for push" do
      work = Fractor::PriorityWork.new("test")
      queue.enqueue(work)
      expect(queue.size).to eq(1)
    end

    it "supports dequeue alias for pop" do
      queue.push(Fractor::PriorityWork.new("test"))
      expect(queue.dequeue.input).to eq("test")
    end

    it "supports shift alias for pop" do
      queue.push(Fractor::PriorityWork.new("test"))
      expect(queue.shift.input).to eq("test")
    end
  end
end
