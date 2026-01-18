# frozen_string_literal: true

require_relative "../../../examples/workflow/fan_out/fan_out_workflow"

RSpec.describe "Fan Out Workflow Example" do
  describe TextInput do
    it "stores text" do
      input = described_class.new(text: "hello")
      expect(input.text).to eq("hello")
    end

    it "defaults to empty text" do
      input = described_class.new
      expect(input.text).to eq("")
    end
  end

  describe ProcessedText do
    it "stores result" do
      output = described_class.new(result: "processed")
      expect(output.result).to eq("processed")
    end

    it "defaults to empty result" do
      output = described_class.new
      expect(output.result).to eq("")
    end
  end

  describe CombinedResult do
    it "stores uppercase, lowercase, and reversed text" do
      result = described_class.new(uppercase: "HELLO", lowercase: "hello",
                                   reversed: "olleh")
      expect(result.uppercase).to eq("HELLO")
      expect(result.lowercase).to eq("hello")
      expect(result.reversed).to eq("olleh")
    end

    it "defaults to empty strings" do
      result = described_class.new
      expect(result.uppercase).to eq("")
      expect(result.lowercase).to eq("")
      expect(result.reversed).to eq("")
    end
  end

  describe FanOutExample::TextSplitter do
    let(:worker) { described_class.new }

    it "passes through text input" do
      input = TextInput.new(text: "hello world")
      work = Fractor::Work.new(input)
      result = worker.process(work)

      expect(result).to be_a(Fractor::WorkResult)
      expect(result.success?).to be true
      expect(result.result).to be_a(TextInput)
      expect(result.result.text).to eq("hello world")
    end
  end

  describe FanOutExample::UppercaseWorker do
    let(:worker) { described_class.new }

    it "converts text to uppercase" do
      input = TextInput.new(text: "hello")
      work = Fractor::Work.new(input)
      result = worker.process(work)

      expect(result).to be_a(Fractor::WorkResult)
      expect(result.success?).to be true
      expect(result.result).to be_a(ProcessedText)
      expect(result.result.result).to eq("HELLO")
    end
  end

  describe FanOutExample::LowercaseWorker do
    let(:worker) { described_class.new }

    it "converts text to lowercase" do
      input = TextInput.new(text: "HELLO")
      work = Fractor::Work.new(input)
      result = worker.process(work)

      expect(result).to be_a(Fractor::WorkResult)
      expect(result.success?).to be true
      expect(result.result).to be_a(ProcessedText)
      expect(result.result.result).to eq("hello")
    end
  end

  describe FanOutExample::ReverseWorker do
    let(:worker) { described_class.new }

    it "reverses text" do
      input = TextInput.new(text: "hello")
      work = Fractor::Work.new(input)
      result = worker.process(work)

      expect(result).to be_a(Fractor::WorkResult)
      expect(result.success?).to be true
      expect(result.result).to be_a(ProcessedText)
      expect(result.result.result).to eq("olleh")
    end
  end

  describe FanOutExample::ResultCombiner do
    let(:worker) { described_class.new }

    it "combines results" do
      input = CombinedResult.new(uppercase: "HELLO", lowercase: "hello",
                                 reversed: "olleh")
      work = Fractor::Work.new(input)
      result = worker.process(work)

      expect(result).to be_a(Fractor::WorkResult)
      expect(result.success?).to be true
      expect(result.result).to be_a(CombinedResult)
      expect(result.result.uppercase).to eq("HELLO")
      expect(result.result.lowercase).to eq("hello")
      expect(result.result.reversed).to eq("olleh")
    end
  end

  describe FanOutWorkflow do
    it "executes the fan-out workflow successfully" do
      input = TextInput.new(text: "Hello World")
      workflow = described_class.new
      result = workflow.execute(input: input)

      expect(result.success?).to be true
      expect(result.output).to be_a(CombinedResult)
      expect(result.output.uppercase).to eq("HELLO WORLD")
      expect(result.output.lowercase).to eq("hello world")
      expect(result.output.reversed).to eq("dlroW olleH")
    end

    it "completes all jobs including fan-out branches" do
      input = TextInput.new(text: "test")
      workflow = described_class.new
      result = workflow.execute(input: input)

      expect(result.completed_jobs).to include("split", "uppercase",
                                               "lowercase", "reverse", "combine")
    end

    it "tracks execution time" do
      input = TextInput.new(text: "fractor")
      workflow = described_class.new
      result = workflow.execute(input: input)

      expect(result.execution_time).to be > 0
    end
  end
end
