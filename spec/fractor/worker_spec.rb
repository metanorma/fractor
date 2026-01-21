# frozen_string_literal: true

module WorkerSpec
  class TestWorker < Fractor::Worker
    def process(work)
      Fractor::WorkResult.new(result: "#{work.input} processed", work: work)
    end
  end
end

RSpec.describe Fractor::Worker do
  before do
    # Reset configuration before each test
    Fractor.configure do |config|
      config.default_worker_timeout = 120
    end
  end

  after do
    # Reset configuration after each test
    Fractor.configure do |config|
      config.default_worker_timeout = 120
    end
  end

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

  describe ".timeout" do
    it "sets a class-level timeout" do
      test_class = Class.new(Fractor::Worker) do
        timeout 30
      end

      expect(test_class.worker_timeout).to eq(30)
    end

    it "can be chained with other definitions" do
      test_class = Class.new(Fractor::Worker) do
        timeout 15

        def process(work)
          Fractor::WorkResult.new(result: work.input, work: work)
        end
      end

      expect(test_class.worker_timeout).to eq(15)
      worker = test_class.new
      expect(worker.timeout).to eq(15)
    end
  end

  describe ".effective_timeout" do
    it "returns class timeout when set" do
      test_class = Class.new(Fractor::Worker) do
        timeout 45
      end

      expect(test_class.effective_timeout).to eq(45)
    end

    it "returns global default when class timeout not set" do
      test_class = Class.new(described_class)

      expect(test_class.effective_timeout).to eq(120)
    end
  end

  describe "#timeout" do
    it "returns class-level timeout by default" do
      test_class = Class.new(Fractor::Worker) do
        timeout 20
      end

      worker = test_class.new
      expect(worker.timeout).to eq(20)
    end

    it "can be overridden via constructor options" do
      test_class = Class.new(Fractor::Worker) do
        timeout 20
      end

      worker = test_class.new(timeout: 10)
      expect(worker.timeout).to eq(10)
    end
  end

  describe "initialization" do
    it "accepts name option" do
      worker = described_class.new(name: "test-worker")
      expect(worker.instance_variable_get(:@name)).to eq("test-worker")
    end

    it "accepts custom options" do
      worker = described_class.new(custom_option: "value")
      expect(worker.instance_variable_get(:@options)[:custom_option]).to eq("value")
    end

    it "stores timeout from options" do
      worker = described_class.new(timeout: 5)
      expect(worker.timeout).to eq(5)
    end
  end
end
