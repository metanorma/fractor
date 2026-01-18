# frozen_string_literal: true

require_relative "../../examples/simple/sample"

RSpec.describe "Simple Example" do
  describe MyWork do
    it "stores the input value" do
      work = described_class.new(42)
      expect(work.value).to eq(42)
    end

    it "provides a string representation" do
      work = described_class.new(10)
      expect(work.to_s).to eq("MyWork: 10")
    end
  end

  describe OtherWork do
    it "stores the input value" do
      work = described_class.new(42)
      expect(work.value).to eq(42)
    end

    it "provides a string representation" do
      work = described_class.new(10)
      expect(work.to_s).to eq("OtherWork: 10")
    end
  end

  describe MyWorker do
    let(:worker) { described_class.new }

    context "processing MyWork" do
      it "doubles the value for normal input" do
        work = MyWork.new(3)
        result = worker.process(work)
        expect(result).to be_a(Fractor::WorkResult)
        expect(result.success?).to be true
        expect(result.result).to eq(6)
      end

      it "returns an error for value 5" do
        work = MyWork.new(5)
        result = worker.process(work)
        expect(result).to be_a(Fractor::WorkResult)
        expect(result.success?).to be false
        expect(result.error).to be_a(StandardError)
        expect(result.error.message).to eq("Cannot process value 5")
      end
    end

    context "processing OtherWork" do
      it "processes the value with a different format" do
        work = OtherWork.new(7)
        result = worker.process(work)
        expect(result).to be_a(Fractor::WorkResult)
        expect(result.success?).to be true
        expect(result.result).to eq("Processed: 7")
      end
    end

    context "processing unsupported work type" do
      it "returns a TypeError" do
        invalid_work = Fractor::Work.new({ value: 1 })
        result = worker.process(invalid_work)
        expect(result).to be_a(Fractor::WorkResult)
        expect(result.success?).to be false
        expect(result.error).to be_a(TypeError)
      end
    end
  end

  describe "Supervisor integration" do
    it "processes work items in parallel" do
      supervisor = Fractor::Supervisor.new(
        worker_pools: [
          { worker_class: MyWorker },
        ],
      )

      work_items = (1..4).map { |i| MyWork.new(i) }
      supervisor.add_work_items(work_items)
      supervisor.run

      results = supervisor.results
      expect(results).to be_a(Fractor::ResultAggregator)
      expect(results.results.size).to be > 0
    end

    it "handles errors properly" do
      supervisor = Fractor::Supervisor.new(
        worker_pools: [
          { worker_class: MyWorker },
        ],
      )

      work_items = [MyWork.new(5)]
      supervisor.add_work_items(work_items)
      supervisor.run

      results = supervisor.results
      expect(results.errors.size).to eq(1)
      expect(results.errors.first.error.message).to eq("Cannot process value 5")
    end
  end
end
