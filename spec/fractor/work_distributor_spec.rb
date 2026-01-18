# frozen_string_literal: true

require "spec_helper"

RSpec.describe Fractor::WorkDistributor do
  let(:work_queue) { Fractor::WorkQueue.new }
  let(:worker_manager) { instance_double(Fractor::WorkerManager) }
  let(:distributor) { described_class.new(work_queue, worker_manager, debug: false) }

  before do
    # Create test work class
    class TestWorkForDistributor < Fractor::Work
      def initialize(value)
        super({ value: value })
      end

      def value
        input[:value]
      end
    end
  end

  after do
    Object.send(:remove_const, :TestWorkForDistributor) if defined?(TestWorkForDistributor)
  end

  describe "#initialize" do
    it "stores work queue" do
      expect(distributor.instance_variable_get(:@work_queue)).to eq(work_queue)
    end

    it "stores worker manager" do
      expect(distributor.instance_variable_get(:@worker_manager)).to eq(worker_manager)
    end
  end

  describe "#queue_size" do
    it "returns the size of the work queue" do
      work_queue << TestWorkForDistributor.new(1)
      work_queue << TestWorkForDistributor.new(2)

      expect(distributor.queue_size).to eq(2)
    end

    it "returns 0 for empty queue" do
      expect(distributor.queue_size).to eq(0)
    end
  end

  describe "#can_distribute?" do
    it "returns true when queue has items and workers are available" do
      work_queue << TestWorkForDistributor.new(1)
      allow(worker_manager).to receive(:idle_workers).and_return([double("worker")])

      expect(distributor.can_distribute?).to be true
    end

    it "returns false when queue is empty" do
      allow(worker_manager).to receive(:idle_workers).and_return([double("worker")])

      expect(distributor.can_distribute?).to be false
    end

    it "returns false when no idle workers" do
      work_queue << TestWorkForDistributor.new(1)
      allow(worker_manager).to receive(:idle_workers).and_return([])

      expect(distributor.can_distribute?).to be false
    end
  end
end
