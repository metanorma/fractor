# frozen_string_literal: true

require "spec_helper"

RSpec.describe Fractor::WorkQueue do
  let(:work_queue) { described_class.new }
  let(:work_item) { Fractor::Work.new("test_data") }

  describe "#initialize" do
    it "creates an empty queue" do
      expect(work_queue.empty?).to be true
      expect(work_queue.size).to eq(0)
    end
  end

  describe "#<<" do
    context "when adding valid work items" do
      it "adds a single work item to the queue" do
        work_queue << work_item
        expect(work_queue.size).to eq(1)
        expect(work_queue.empty?).to be false
      end

      it "adds multiple work items to the queue" do
        items = 5.times.map { |i| Fractor::Work.new("data_#{i}") }
        items.each { |item| work_queue << item }
        expect(work_queue.size).to eq(5)
      end
    end

    context "when adding invalid work items" do
      it "raises ArgumentError for non-Work objects" do
        expect { work_queue << "not a work item" }.to raise_error(
          ArgumentError,
          /must be an instance of Fractor::Work/
        )
      end

      it "raises ArgumentError for nil" do
        expect { work_queue << nil }.to raise_error(
          ArgumentError,
          /must be an instance of Fractor::Work/
        )
      end
    end

    context "when used concurrently" do
      it "handles concurrent pushes safely" do
        threads = 10.times.map do
          Thread.new do
            5.times { |i| work_queue << Fractor::Work.new("concurrent_#{i}") }
          end
        end
        threads.each(&:join)

        expect(work_queue.size).to eq(50)
      end
    end
  end

  describe "#pop_batch" do
    context "when queue is empty" do
      it "returns empty array" do
        result = work_queue.pop_batch(5)
        expect(result).to eq([])
      end
    end

    context "when queue has fewer items than requested" do
      it "returns all available items" do
        3.times { |i| work_queue << Fractor::Work.new("data_#{i}") }
        result = work_queue.pop_batch(5)
        expect(result.size).to eq(3)
        expect(work_queue.empty?).to be true
      end
    end

    context "when queue has more items than requested" do
      it "returns only the requested number of items" do
        10.times { |i| work_queue << Fractor::Work.new("data_#{i}") }
        result = work_queue.pop_batch(5)
        expect(result.size).to eq(5)
        expect(work_queue.size).to eq(5)
      end
    end

    context "when queue has exact number of items requested" do
      it "returns all items" do
        5.times { |i| work_queue << Fractor::Work.new("data_#{i}") }
        result = work_queue.pop_batch(5)
        expect(result.size).to eq(5)
        expect(work_queue.empty?).to be true
      end
    end

    context "with default batch size" do
      it "retrieves up to 10 items by default" do
        15.times { |i| work_queue << Fractor::Work.new("data_#{i}") }
        result = work_queue.pop_batch
        expect(result.size).to eq(10)
        expect(work_queue.size).to eq(5)
      end
    end

    context "when used concurrently" do
      it "handles concurrent pops safely without duplicates" do
        100.times { |i| work_queue << Fractor::Work.new("data_#{i}") }

        results = []
        results_mutex = Mutex.new

        threads = 10.times.map do
          Thread.new do
            batch = work_queue.pop_batch(10)
            results_mutex.synchronize { results.concat(batch) }
          end
        end
        threads.each(&:join)

        expect(results.size).to eq(100)
        expect(work_queue.empty?).to be true
      end
    end
  end

  describe "#empty?" do
    it "returns true when queue is empty" do
      expect(work_queue.empty?).to be true
    end

    it "returns false when queue has items" do
      work_queue << work_item
      expect(work_queue.empty?).to be false
    end

    it "returns true after all items are popped" do
      work_queue << work_item
      work_queue.pop_batch(1)
      expect(work_queue.empty?).to be true
    end
  end

  describe "#size" do
    it "returns 0 for empty queue" do
      expect(work_queue.size).to eq(0)
    end

    it "returns correct size after adding items" do
      5.times { |i| work_queue << Fractor::Work.new("data_#{i}") }
      expect(work_queue.size).to eq(5)
    end

    it "returns correct size after popping items" do
      10.times { |i| work_queue << Fractor::Work.new("data_#{i}") }
      work_queue.pop_batch(3)
      expect(work_queue.size).to eq(7)
    end
  end

  describe "#register_with_supervisor" do
    let(:supervisor) do
      Fractor::Supervisor.new(
        worker_pools: [],
        continuous_mode: true
      )
    end

    it "registers a work source callback with the supervisor" do
      work_queue.register_with_supervisor(supervisor)

      # Add items to queue
      5.times { |i| work_queue << Fractor::Work.new("data_#{i}") }

      # Trigger work source callback manually
      new_work = supervisor.instance_variable_get(:@work_callbacks).first.call
      expect(new_work).to be_an(Array)
      expect(new_work.size).to be <= 10
    end

    it "respects custom batch size" do
      work_queue.register_with_supervisor(supervisor, batch_size: 3)

      10.times { |i| work_queue << Fractor::Work.new("data_#{i}") }

      # Trigger work source callback manually
      new_work = supervisor.instance_variable_get(:@work_callbacks).first.call
      expect(new_work.size).to eq(3)
    end

    it "returns nil when queue is empty" do
      work_queue.register_with_supervisor(supervisor)

      # Trigger work source callback manually with empty queue
      new_work = supervisor.instance_variable_get(:@work_callbacks).first.call
      expect(new_work).to be_nil
    end
  end
end
