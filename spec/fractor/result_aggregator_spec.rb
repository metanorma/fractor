# frozen_string_literal: true

RSpec.describe Fractor::ResultAggregator do
  let(:success_result) { Fractor::WorkResult.new(result: "success data", work: Fractor::Work.new("test input")) }
  let(:error_result) { Fractor::WorkResult.new(error: "error message", work: Fractor::Work.new("error input")) }

  describe "#initialize" do
    it "initializes with empty results and errors arrays" do
      aggregator = Fractor::ResultAggregator.new

      expect(aggregator.results).to be_an(Array)
      expect(aggregator.results).to be_empty
      expect(aggregator.errors).to be_an(Array)
      expect(aggregator.errors).to be_empty
    end
  end

  describe "#add_result" do
    let(:aggregator) { Fractor::ResultAggregator.new }

    it "adds successful results to the results array" do
      expect { aggregator.add_result(success_result) }
        .to change { aggregator.results.size }.from(0).to(1)

      expect(aggregator.results.first).to eq(success_result)
      expect(aggregator.errors).to be_empty
    end

    it "adds error results to the errors array" do
      expect { aggregator.add_result(error_result) }
        .to change { aggregator.errors.size }.from(0).to(1)

      expect(aggregator.errors.first).to eq(error_result)
      expect(aggregator.results).to be_empty
    end

    it "handles multiple results correctly" do
      # Add multiple results
      aggregator.add_result(success_result)
      aggregator.add_result(error_result)
      aggregator.add_result(success_result)

      # Check the counts are correct
      expect(aggregator.results.size).to eq(2)
      expect(aggregator.errors.size).to eq(1)

      # Check the results were added in the correct arrays
      aggregator.results.each do |result|
        expect(result.success?).to be true
      end

      aggregator.errors.each do |result|
        expect(result.success?).to be false
      end
    end
  end

  describe "#to_s" do
    it "returns a string with counts of results and errors" do
      aggregator = Fractor::ResultAggregator.new

      # Add some results
      2.times { aggregator.add_result(success_result) }
      aggregator.add_result(error_result)

      expect(aggregator.to_s).to eq("Results: 2, Errors: 1")
    end
  end

  describe "#inspect" do
    it "returns a hash with results and errors" do
      aggregator = Fractor::ResultAggregator.new

      # Add some results
      aggregator.add_result(success_result)
      aggregator.add_result(error_result)

      inspected = aggregator.inspect

      expect(inspected).to be_a(Hash)
      expect(inspected[:results]).to be_an(Array)
      expect(inspected[:results].size).to eq(1)
      expect(inspected[:errors]).to be_an(Array)
      expect(inspected[:errors].size).to eq(1)
    end
  end
end
