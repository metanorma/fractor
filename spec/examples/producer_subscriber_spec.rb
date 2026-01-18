# frozen_string_literal: true

require_relative "../../examples/producer_subscriber/producer_subscriber"

RSpec.describe ProducerSubscriber do
  describe ProducerSubscriber::InitialWork do
    it "stores data and depth" do
      work = described_class.new("document", 1)
      expect(work.data).to eq("document")
      expect(work.depth).to eq(1)
    end

    it "defaults to depth 0" do
      work = described_class.new("document")
      expect(work.depth).to eq(0)
    end

    it "provides a string representation" do
      work = described_class.new("test", 2)
      expect(work.to_s).to include("InitialWork", "test", "2")
    end
  end

  describe ProducerSubscriber::SubWork do
    it "stores data, parent_id, and depth" do
      work = described_class.new("section", 123, 1)
      expect(work.data).to eq("section")
      expect(work.parent_id).to eq(123)
      expect(work.depth).to eq(1)
    end

    it "defaults parent_id to nil" do
      work = described_class.new("section")
      expect(work.parent_id).to be_nil
    end

    it "defaults to depth 0" do
      work = described_class.new("section", 123)
      expect(work.depth).to eq(0)
    end

    it "provides a string representation" do
      work = described_class.new("test", 456, 2)
      expect(work.to_s).to include("SubWork", "test", "456", "2")
    end
  end

  describe ProducerSubscriber::MultiWorker do
    let(:worker) { described_class.new }

    context "processing InitialWork" do
      it "processes initial work successfully" do
        work = ProducerSubscriber::InitialWork.new("document", 0)
        result = worker.process(work)

        expect(result).to be_a(Fractor::WorkResult)
        expect(result.success?).to be true
        expect(result.result[:processed_data]).to include("Processed")
        expect(result.result[:sub_works]).to eq([])
      end

      it "handles different depths" do
        work1 = ProducerSubscriber::InitialWork.new("doc1", 0)
        work2 = ProducerSubscriber::InitialWork.new("doc2", 1)

        result1 = worker.process(work1)
        result2 = worker.process(work2)

        expect(result1.success?).to be true
        expect(result2.success?).to be true
      end
    end

    context "processing SubWork" do
      it "processes sub-work successfully" do
        work = ProducerSubscriber::SubWork.new("section", 123, 1)
        result = worker.process(work)

        expect(result).to be_a(Fractor::WorkResult)
        expect(result.success?).to be true
        expect(result.result[:processed_data]).to include("Sub-processed",
                                                          "section")
        expect(result.result[:parent_id]).to eq(123)
      end

      it "includes depth in processed data" do
        work = ProducerSubscriber::SubWork.new("data", 456, 2)
        result = worker.process(work)

        expect(result.result[:processed_data]).to include("depth: 2")
      end
    end

    context "unknown work type" do
      it "returns an error for unknown work" do
        work = Fractor::Work.new({ value: 1 })
        result = worker.process(work)

        expect(result.success?).to be false
        expect(result.error).to include("Unknown work type")
      end
    end
  end

  describe ProducerSubscriber::DocumentProcessor do
    let(:documents) { ["Doc1", "Doc2"] }
    let(:processor) { described_class.new(documents, 2) }

    it "initializes with documents and worker count" do
      expect(processor.documents).to eq(documents)
      expect(processor.worker_count).to eq(2)
    end

    it "processes documents" do
      result = processor.process

      expect(result).to be_a(String)
      expect(result).not_to be_empty
    end

    it "builds a result tree" do
      processor.process

      expect(processor.result_tree).to be_a(Hash)
      expect(processor.result_tree).not_to be_empty
    end

    it "handles empty document list" do
      empty_processor = described_class.new([], 2)
      result = empty_processor.process

      expect(result).to be_a(String)
      expect(empty_processor.result_tree).to be_empty
    end

    it "creates hierarchical structure" do
      result = processor.process

      # Should have root and child entries
      expect(result).to include("Root:")
      expect(result).to include("Child")
    end
  end
end
