# frozen_string_literal: true

require_relative "../../examples/scatter_gather/scatter_gather"

RSpec.describe ScatterGather do
  describe ScatterGather::SearchWork do
    it "stores query, source, and query_params" do
      work = described_class.new("test query", :database, { max: 10 })
      expect(work.query).to eq("test query")
      expect(work.source).to eq(:database)
      expect(work.query_params).to eq({ max: 10 })
    end

    it "defaults to default source" do
      work = described_class.new("query")
      expect(work.source).to eq(:default)
    end

    it "defaults to empty query_params" do
      work = described_class.new("query", :api)
      expect(work.query_params).to eq({})
    end

    it "provides a string representation" do
      work = described_class.new("test", :cache)
      expect(work.to_s).to include("SearchWork", "cache", "test")
    end
  end

  describe ScatterGather::SearchWorker do
    let(:worker) { described_class.new }

    context "searching database" do
      it "performs database search" do
        work = ScatterGather::SearchWork.new("ruby", :database)
        result = worker.process(work)

        expect(result).to be_a(Fractor::WorkResult)
        expect(result.success?).to be true
        expect(result.result[:source]).to eq(:database)
        expect(result.result[:hits]).to be_an(Array)
        expect(result.result[:hits]).not_to be_empty
      end

      it "includes metadata and timing" do
        work = ScatterGather::SearchWork.new("test", :database)
        result = worker.process(work)

        expect(result.result[:metadata]).to be_a(Hash)
        expect(result.result[:timing]).to be_a(Numeric)
      end
    end

    context "searching API" do
      it "performs API search" do
        work = ScatterGather::SearchWork.new("ruby", :api)
        result = worker.process(work)

        expect(result.success?).to be true
        expect(result.result[:source]).to eq(:api)
        expect(result.result[:hits]).to be_an(Array)
      end
    end

    context "searching cache" do
      it "performs cache lookup" do
        work = ScatterGather::SearchWork.new("ruby", :cache)
        result = worker.process(work)

        expect(result.success?).to be true
        expect(result.result[:source]).to eq(:cache)
        expect(result.result[:metadata][:cache_hit]).to be_a(TrueClass).or be_a(FalseClass)
      end
    end

    context "searching filesystem" do
      it "performs filesystem search" do
        work = ScatterGather::SearchWork.new("ruby", :filesystem)
        result = worker.process(work)

        expect(result.success?).to be true
        expect(result.result[:source]).to eq(:filesystem)
        expect(result.result[:hits]).to be_an(Array)
      end
    end

    context "unknown source" do
      it "returns an error for unknown source" do
        work = ScatterGather::SearchWork.new("query", :unknown)
        result = worker.process(work)

        expect(result.success?).to be false
        expect(result.error).to be_an(ArgumentError)
      end
    end
  end

  describe ScatterGather::MultiSourceSearch do
    let(:search) { described_class.new(2) }

    it "searches multiple sources in parallel" do
      sources = [
        { source: :database, params: {} },
        { source: :api, params: {} },
      ]

      results = search.search("ruby", sources)

      expect(results).to be_a(Hash)
      expect(results[:query]).to eq("ruby")
      expect(results[:total_hits]).to be >= 0
      expect(results[:sources]).to include(:database, :api)
    end

    it "merges and ranks results" do
      results = search.search("test")

      expect(results[:ranked_results]).to be_an(Array)
      expect(results[:source_details]).to be_a(Hash)
    end

    it "includes execution time" do
      results = search.search("query")

      expect(results[:execution_time]).to be_a(Numeric)
      expect(results[:execution_time]).to be > 0
    end

    it "ranks results by weighted relevance" do
      results = search.search("test")

      if results[:ranked_results].size > 1
        first_relevance = results[:ranked_results][0][:weighted_relevance]
        second_relevance = results[:ranked_results][1][:weighted_relevance]
        expect(first_relevance).to be >= second_relevance
      end
    end

    it "provides source-specific details" do
      results = search.search("test")

      results[:source_details].each_value do |details|
        expect(details).to have_key(:hits)
        expect(details).to have_key(:metadata)
        expect(details).to have_key(:timing)
      end
    end

    it "handles custom sources list" do
      sources = [{ source: :cache, params: {} }]
      results = search.search("test", sources)

      expect(results[:sources]).to eq([:cache])
    end
  end
end
