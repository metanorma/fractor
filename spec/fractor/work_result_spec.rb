# frozen_string_literal: true

RSpec.describe Fractor::WorkResult do
  let(:sample_work) { Fractor::Work.new("test input") }

  describe "#initialize" do
    it "initializes with a result" do
      result = described_class.new(result: "success", work: sample_work)

      expect(result.result).to eq("success")
      expect(result.error).to be_nil
      expect(result.work).to eq(sample_work)
    end

    it "initializes with an error" do
      result = described_class.new(error: "failed", work: sample_work)

      expect(result.result).to be_nil
      expect(result.error).to eq("failed")
      expect(result.work).to eq(sample_work)
    end

    it "initializes with only required parameters" do
      result = described_class.new

      expect(result.result).to be_nil
      expect(result.error).to be_nil
      expect(result.work).to be_nil
    end
  end

  describe "#success?" do
    it "returns true when no error is present" do
      result = described_class.new(result: "success")
      expect(result.success?).to be true
    end

    it "returns false when an error is present" do
      result = described_class.new(error: "failed")
      expect(result.success?).to be false
    end
  end

  describe "#to_s" do
    it "returns a success message when successful" do
      result = described_class.new(result: "success data")
      expect(result.to_s).to eq("Result: success data")
    end

    it "returns an error message when failed" do
      result = described_class.new(error: "failed", work: sample_work)
      expect(result.to_s).to eq("Error: failed, Work: Work: test input")
    end
  end

  describe "#inspect" do
    it "returns a hash with result for successful results" do
      result = described_class.new(result: "success", work: sample_work)
      inspected = result.inspect

      expect(inspected).to be_a(Hash)
      expect(inspected[:result]).to eq("success")
      expect(inspected[:error]).to be_nil
      expect(inspected[:work]).to eq("Work: test input")
    end

    it "returns a hash with error for failed results" do
      result = described_class.new(error: "failed", work: sample_work)
      inspected = result.inspect

      expect(inspected).to be_a(Hash)
      expect(inspected[:result]).to be_nil
      expect(inspected[:error]).to eq("failed")
      expect(inspected[:work]).to eq("Work: test input")
    end

    it "handles nil work safely" do
      result = described_class.new(result: "success", work: nil)
      inspected = result.inspect

      expect(inspected).to be_a(Hash)
      expect(inspected[:work]).to be_nil
    end
  end
end
