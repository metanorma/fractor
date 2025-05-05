# frozen_string_literal: true

RSpec.describe Fractor do
  it "has a version number" do
    expect(Fractor::VERSION).not_to be nil
  end

  context "components" do
    it "has core components" do
      # Verify core components exist
      expect(defined?(Fractor::Worker)).to eq("constant")
      expect(defined?(Fractor::Work)).to eq("constant")
      expect(defined?(Fractor::WorkResult)).to eq("constant")
      expect(defined?(Fractor::ResultAggregator)).to eq("constant")
      expect(defined?(Fractor::WrappedRactor)).to eq("constant")
      expect(defined?(Fractor::Supervisor)).to eq("constant")
    end
  end
end
