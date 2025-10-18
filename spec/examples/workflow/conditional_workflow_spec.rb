# frozen_string_literal: true

require_relative "../../../examples/workflow/conditional/conditional_workflow"

RSpec.describe "Conditional Workflow Example" do
  describe NumberInput do
    it "stores value" do
      input = described_class.new(value: 42)
      expect(input.value).to eq(42)
    end

    it "defaults to zero" do
      input = described_class.new
      expect(input.value).to eq(0)
    end
  end

  describe ValidationResult do
    it "stores is_positive and is_even flags" do
      result = described_class.new(is_positive: true, is_even: false)
      expect(result.is_positive).to be true
      expect(result.is_even).to be false
    end

    it "defaults to false values" do
      result = described_class.new
      expect(result.is_positive).to be false
      expect(result.is_even).to be false
    end
  end

  describe ProcessedNumber do
    it "stores result and operation" do
      output = described_class.new(result: 10, operation: "doubled")
      expect(output.result).to eq(10)
      expect(output.operation).to eq("doubled")
    end

    it "defaults to zero and empty string" do
      output = described_class.new
      expect(output.result).to eq(0)
      expect(output.operation).to eq("")
    end
  end

  describe ConditionalExample::ValidatorWorker do
    let(:worker) { described_class.new }

    it "validates positive even number" do
      input = NumberInput.new(value: 4)
      work = Fractor::Work.new(input)
      result = worker.process(work)

      expect(result).to be_a(Fractor::WorkResult)
      expect(result.success?).to be true
      expect(result.result).to be_a(ValidationResult)
      expect(result.result.is_positive).to be true
      expect(result.result.is_even).to be true
    end

    it "validates negative odd number" do
      input = NumberInput.new(value: -3)
      work = Fractor::Work.new(input)
      result = worker.process(work)

      expect(result.result.is_positive).to be false
      expect(result.result.is_even).to be false
    end
  end

  describe ConditionalExample::DoubleWorker do
    let(:worker) { described_class.new }

    it "doubles the number" do
      input = NumberInput.new(value: 5)
      work = Fractor::Work.new(input)
      result = worker.process(work)

      expect(result).to be_a(Fractor::WorkResult)
      expect(result.success?).to be true
      expect(result.result).to be_a(ProcessedNumber)
      expect(result.result.result).to eq(10)
      expect(result.result.operation).to eq("doubled")
    end
  end

  describe ConditionalExample::SquareWorker do
    let(:worker) { described_class.new }

    it "squares the number" do
      input = NumberInput.new(value: 4)
      work = Fractor::Work.new(input)
      result = worker.process(work)

      expect(result).to be_a(Fractor::WorkResult)
      expect(result.success?).to be true
      expect(result.result).to be_a(ProcessedNumber)
      expect(result.result.result).to eq(16)
      expect(result.result.operation).to eq("squared")
    end
  end

  describe ConditionalExample::PassThroughWorker do
    let(:worker) { described_class.new }

    it "keeps the original value" do
      input = NumberInput.new(value: -3)
      work = Fractor::Work.new(input)
      result = worker.process(work)

      expect(result).to be_a(Fractor::WorkResult)
      expect(result.success?).to be true
      expect(result.result).to be_a(ProcessedNumber)
      expect(result.result.result).to eq(-3)
      expect(result.result.operation).to eq("unchanged")
    end
  end

  describe ConditionalWorkflow do
    it "doubles positive numbers" do
      input = NumberInput.new(value: 5)
      workflow = described_class.new
      result = workflow.execute(input: input)

      expect(result.success?).to be true
      expect(result.output).to be_a(ProcessedNumber)
      expect(result.output.result).to eq(10)
      expect(result.output.operation).to eq("doubled")
    end

    it "squares negative even numbers" do
      input = NumberInput.new(value: -4)
      workflow = described_class.new
      result = workflow.execute(input: input)

      expect(result.success?).to be true
      expect(result.output.result).to eq(16)
      expect(result.output.operation).to eq("squared")
    end

    it "passes through negative odd numbers" do
      input = NumberInput.new(value: -3)
      workflow = described_class.new
      result = workflow.execute(input: input)

      expect(result.success?).to be true
      expect(result.output.result).to eq(-3)
      expect(result.output.operation).to eq("unchanged")
    end

    it "completes validation job in all cases" do
      input = NumberInput.new(value: 5)
      workflow = described_class.new
      result = workflow.execute(input: input)

      expect(result.completed_jobs).to include("validate")
    end

    it "tracks execution time" do
      input = NumberInput.new(value: 10)
      workflow = described_class.new
      result = workflow.execute(input: input)

      expect(result.execution_time).to be > 0
    end
  end
end
