# frozen_string_literal: true

require_relative "../../examples/auto_detection/auto_detection"

RSpec.describe "Auto Detection Example" do
  describe ComputeWork do
    it "stores the input value" do
      work = described_class.new(42)
      expect(work.value).to eq(42)
    end

    it "provides a string representation" do
      work = described_class.new(10)
      expect(work.to_s).to eq("ComputeWork: 10")
    end
  end

  describe ComputeWorker do
    let(:worker) { described_class.new }

    it "squares the input value" do
      work = ComputeWork.new(5)
      result = worker.process(work)
      expect(result).to be_a(Fractor::WorkResult)
      expect(result.success?).to be true
      expect(result.result).to eq(25)
    end

    it "handles zero correctly" do
      work = ComputeWork.new(0)
      result = worker.process(work)
      expect(result.success?).to be true
      expect(result.result).to eq(0)
    end

    it "handles negative numbers" do
      work = ComputeWork.new(-3)
      result = worker.process(work)
      expect(result.success?).to be true
      expect(result.result).to eq(9)
    end
  end

  describe "Auto-detection functionality" do
    it "processes work items with auto-detected workers" do
      supervisor = Fractor::Supervisor.new(
        worker_pools: [
          { worker_class: ComputeWorker },
        ],
      )

      work_items = (1..5).map { |i| ComputeWork.new(i) }
      supervisor.add_work_items(work_items)
      supervisor.run

      results = supervisor.results
      expect(results.results.size).to eq(5)
      expect(results.errors).to be_empty

      squared_values = results.results.map(&:result).sort
      expect(squared_values).to eq([1, 4, 9, 16, 25])
    end

    it "processes work items with explicit worker count" do
      supervisor = Fractor::Supervisor.new(
        worker_pools: [
          { worker_class: ComputeWorker, num_workers: 2 },
        ],
      )

      work_items = (1..5).map { |i| ComputeWork.new(i) }
      supervisor.add_work_items(work_items)
      supervisor.run

      results = supervisor.results
      expect(results.results.size).to eq(5)
      expect(results.errors).to be_empty
    end

    it "handles mixed configuration with multiple worker pools" do
      supervisor = Fractor::Supervisor.new(
        worker_pools: [
          { worker_class: ComputeWorker },
          { worker_class: ComputeWorker, num_workers: 2 },
        ],
      )

      work_items = (1..10).map { |i| ComputeWork.new(i) }
      supervisor.add_work_items(work_items)
      supervisor.run

      results = supervisor.results
      expect(results.results.size).to eq(10)
      expect(results.errors).to be_empty
    end
  end
end
