# frozen_string_literal: true

require "spec_helper"

RSpec.describe Fractor::WorkerManager do
  let(:worker_pools) do
    [
      { worker_class: TestWorker, num_workers: 2 },
    ]
  end

  let(:manager) { described_class.new(worker_pools, debug: false) }

  before do
    # Define a simple test worker
    class TestWorker < Fractor::Worker
      def initialize(name: nil)
        @name = name
      end

      def process(work)
        Fractor::WorkResult.new(result: work.input * 2, work: work)
      end
    end
  end

  after do
    Object.send(:remove_const, :TestWorker) if defined?(TestWorker)
  end

  describe "#initialize" do
    it "initializes with worker pools" do
      expect(manager.worker_pools).to eq(worker_pools)
    end

    it "initializes with empty workers array" do
      expect(manager.workers).to be_empty
    end

    it "initializes with empty actors_map" do
      expect(manager.ractors_map).to be_empty
    end
  end

  describe "#start_all" do
    it "creates the specified number of workers" do
      manager.start_all
      expect(manager.workers.size).to eq(2)
    end

    it "creates wakeup ractor" do
      manager.start_all
      # The wakeup ractor is stored with :wakeup as the value, not key
      expect(manager.ractors_map.values).to include(:wakeup)
    end

    it "stores workers in worker pools" do
      manager.start_all
      expect(manager.worker_pools.first[:workers].size).to eq(2)
    end
  end

  describe "#idle_workers" do
    it "returns empty array (simplified implementation)" do
      manager.start_all
      # Simplified: returns empty until fully integrated with work distribution
      expect(manager.idle_workers).to eq([])
    end
  end

  describe "#busy_workers" do
    it "returns empty array (simplified implementation)" do
      manager.start_all
      # Simplified: returns empty until fully integrated with work distribution
      expect(manager.busy_workers).to eq([])
    end
  end

  describe "#status_summary" do
    it "returns worker status summary" do
      manager.start_all
      summary = manager.status_summary

      expect(summary[:total]).to eq(2)
      expect(summary[:idle]).to eq(0)  # Simplified implementation
      expect(summary[:busy]).to eq(0)  # Simplified implementation
    end
  end

  describe "#shutdown_all" do
    it "clears workers array" do
      manager.start_all
      manager.shutdown_all
      expect(manager.workers).to be_empty
    end

    it "clears actors_map" do
      manager.start_all
      manager.shutdown_all
      expect(manager.ractors_map).to be_empty
    end
  end
end
