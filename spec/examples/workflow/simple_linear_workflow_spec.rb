# frozen_string_literal: true

require_relative "../../../examples/workflow/simple_linear/simple_linear_workflow"

RSpec.describe "Simple Linear Workflow Example" do
  describe SimpleLinear::TextData do
    it "stores text" do
      data = described_class.new(text: "hello")
      expect(data.text).to eq("hello")
    end
  end

  describe SimpleLinear::UppercaseOutput do
    it "stores uppercased text and char count" do
      output = described_class.new(uppercased_text: "HELLO", char_count: 5)
      expect(output.uppercased_text).to eq("HELLO")
      expect(output.char_count).to eq(5)
    end
  end

  describe SimpleLinear::ReversedOutput do
    it "stores reversed text and word count" do
      output = described_class.new(reversed_text: "OLLEH", word_count: 1)
      expect(output.reversed_text).to eq("OLLEH")
      expect(output.word_count).to eq(1)
    end
  end

  describe SimpleLinear::FinalOutput do
    it "stores result and total operations" do
      output = described_class.new(result: "OLLEH", total_operations: 3)
      expect(output.result).to eq("OLLEH")
      expect(output.total_operations).to eq(3)
    end
  end

  describe SimpleLinearExample::UppercaseWorker do
    let(:worker) { described_class.new }

    it "converts text to uppercase" do
      input = SimpleLinear::TextData.new(text: "hello world")
      work = Fractor::Work.new(input)
      result = worker.process(work)

      expect(result).to be_a(Fractor::WorkResult)
      expect(result.success?).to be true
      expect(result.result).to be_a(SimpleLinear::UppercaseOutput)
      expect(result.result.uppercased_text).to eq("HELLO WORLD")
      expect(result.result.char_count).to eq(11)
    end
  end

  describe SimpleLinearExample::ReverseWorker do
    let(:worker) { described_class.new }

    it "reverses uppercased text" do
      input = SimpleLinear::UppercaseOutput.new(uppercased_text: "HELLO WORLD",
                                                char_count: 11)
      work = Fractor::Work.new(input)
      result = worker.process(work)

      expect(result).to be_a(Fractor::WorkResult)
      expect(result.success?).to be true
      expect(result.result).to be_a(SimpleLinear::ReversedOutput)
      expect(result.result.reversed_text).to eq("DLROW OLLEH")
      expect(result.result.word_count).to eq(2)
    end
  end

  describe SimpleLinearExample::FinalizeWorker do
    let(:worker) { described_class.new }

    it "creates final output" do
      input = SimpleLinear::ReversedOutput.new(reversed_text: "DLROW OLLEH",
                                               word_count: 2)
      work = Fractor::Work.new(input)
      result = worker.process(work)

      expect(result).to be_a(Fractor::WorkResult)
      expect(result.success?).to be true
      expect(result.result).to be_a(SimpleLinear::FinalOutput)
      expect(result.result.result).to eq("DLROW OLLEH")
      expect(result.result.total_operations).to eq(3)
    end
  end

  describe SimpleLinearWorkflow do
    it "executes the workflow successfully" do
      input = SimpleLinear::TextData.new(text: "hello world")
      workflow = described_class.new
      result = workflow.execute(input: input)

      expect(result.success?).to be true
      expect(result.output).to be_a(SimpleLinear::FinalOutput)
      expect(result.output.result).to eq("DLROW OLLEH")
      expect(result.output.total_operations).to eq(3)
    end

    it "completes all jobs in sequence" do
      input = SimpleLinear::TextData.new(text: "test")
      workflow = described_class.new
      result = workflow.execute(input: input)

      expect(result.completed_jobs).to include("uppercase", "reverse",
                                               "finalize")
    end

    it "tracks execution time" do
      input = SimpleLinear::TextData.new(text: "fractor")
      workflow = described_class.new
      result = workflow.execute(input: input)

      expect(result.execution_time).to be > 0
    end
  end
end
