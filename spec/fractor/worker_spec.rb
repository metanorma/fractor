# frozen_string_literal: true

module WorkerSpec
  class TestWorker < Fractor::Worker
    def process(work)
      Fractor::WorkResult.new(result: "#{work.input} processed", work: work)
    end
  end
end

RSpec.describe Fractor::Worker do
  describe "#process" do
    it "raises NotImplementedError when not overridden" do
      worker = described_class.new
      work = Fractor::Work.new("test")

      expect do
        worker.process(work)
      end.to raise_error(NotImplementedError,
                         "Subclasses must implement the 'process' method.")
    end

    it "can be overridden by a subclass" do
      # Define a test subclass inside the test

      worker = WorkerSpec::TestWorker.new
      work = Fractor::Work.new("test")
      result = worker.process(work)

      expect(result).to be_a(Fractor::WorkResult)
      expect(result.success?).to be true
      expect(result.result).to eq("test processed")
    end
  end
end
