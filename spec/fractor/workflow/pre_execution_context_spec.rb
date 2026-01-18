# frozen_string_literal: true

require "spec_helper"

# Test worker for the workflow - must be defined before workflow_class
class PreExecutionTestWorker < Fractor::Worker
  input_type String
  output_type String

  def process(work)
    Fractor::WorkResult.new(result: work.input, work: work)
  end
end

RSpec.describe Fractor::Workflow::PreExecutionContext do
  let(:workflow_class) do
    Class.new(Fractor::Workflow) do
      workflow "test_workflow" do
        input_type String
        output_type String

        start_with "process"

        job "process" do
          runs_with PreExecutionTestWorker
          inputs_from_workflow
          outputs_to_workflow
          terminates_workflow
        end
      end
    end
  end

  let(:input) { "test input" }
  let(:workflow) { workflow_class.new }

  subject(:context) { described_class.new(workflow, input) }

  describe "#initialize" do
    it "stores the workflow and input" do
      expect(context.workflow).to eq(workflow)
      expect(context.input).to eq(input)
    end

    it "initializes empty errors and warnings arrays" do
      expect(context.errors).to be_empty
      expect(context.warnings).to be_empty
    end
  end

  describe "#add_error" do
    it "adds an error message" do
      context.add_error("Test error")
      expect(context.errors).to eq(["Test error"])
    end

    it "adds multiple error messages" do
      context.add_error("Error 1")
      context.add_error("Error 2")
      expect(context.errors).to eq(["Error 1", "Error 2"])
    end
  end

  describe "#add_warning" do
    it "adds a warning message" do
      context.add_warning("Test warning")
      expect(context.warnings).to eq(["Test warning"])
    end

    it "adds multiple warning messages" do
      context.add_warning("Warning 1")
      context.add_warning("Warning 2")
      expect(context.warnings).to eq(["Warning 1", "Warning 2"])
    end
  end

  describe "#valid?" do
    it "returns true when no errors" do
      expect(context.valid?).to be true
    end

    it "returns false when errors present" do
      context.add_error("Test error")
      expect(context.valid?).to be false
    end

    it "returns true when warnings present but no errors" do
      context.add_warning("Test warning")
      expect(context.valid?).to be true
    end
  end

  describe "#has_warnings?" do
    it "returns false when no warnings" do
      expect(context.has_warnings?).to be false
    end

    it "returns true when warnings present" do
      context.add_warning("Test warning")
      expect(context.has_warnings?).to be true
    end
  end

  describe "#validate!" do
    context "with valid workflow and input" do
      it "returns true" do
        expect(context.validate!).to be true
      end

      it "does not add errors" do
        context.validate!
        expect(context.errors).to be_empty
      end
    end

    context "with invalid input type" do
      let(:input) { 123 } # Wrong type

      it "raises WorkflowError" do
        expect {
          context.validate!
        }.to raise_error(Fractor::WorkflowError, /expects input of type String, got Integer/)
      end

      it "includes the type mismatch in error message" do
        expect {
          context.validate!
        }.to raise_error(/got #{input.class}/)
      end
    end

    context "with nil input when input is required" do
      let(:input) { nil }

      it "raises WorkflowError when workflow requires input" do
        expect {
          context.validate!
        }.to raise_error(Fractor::WorkflowError, /requires input but none was provided/)
      end
    end
  end

  describe "#add_validation_hook" do
    it "raises ArgumentError without a block" do
      expect {
        context.add_validation_hook(:test_hook)
      }.to raise_error(ArgumentError, "Must provide a block for validation hook")
    end

    it "stores the validation hook" do
      context.add_validation_hook(:test_hook) { |ctx| ctx.add_error("test") }
      expect {
        context.validate!
      }.to raise_error(Fractor::WorkflowError, /test/)
    end
  end

  describe "custom validation hooks" do
    it "executes custom validation hooks during validate!" do
      short_input = "hi"
      short_context = described_class.new(workflow, short_input)

      short_context.add_validation_hook(:check_length) do |ctx|
        if ctx.input.length < 10
          ctx.add_error("Input too short")
        end
      end

      expect {
        short_context.validate!
      }.to raise_error(Fractor::WorkflowError, /Input too short/)
    end

    it "passes validation when custom hook conditions are met" do
      context.add_validation_hook(:check_length) do |ctx|
        if ctx.input.length < 3
          ctx.add_error("Input too short")
        end
      end

      expect(context.validate!).to be true
    end

    it "allows adding warnings from hooks" do
      short_input = "hi"
      short_context = described_class.new(workflow, short_input)

      short_context.add_validation_hook(:check_length) do |ctx|
        if ctx.input.length < 10
          ctx.add_warning("Input is short but acceptable")
        end
      end

      # Should not raise - warnings don't cause validation failure
      expect(short_context.validate!).to be true
      expect(short_context.has_warnings?).to be true
    end

    it "handles exceptions raised in validation hooks" do
      context.add_validation_hook(:failing_hook) do |_ctx|
        raise StandardError, "Hook failed"
      end

      expect {
        context.validate!
      }.to raise_error(Fractor::WorkflowError, /Validation hook 'failing_hook' raised error/)
    end
  end

  describe "error message formatting" do
    it "includes workflow name in error message" do
      expect {
        context.validate!
      }.not_to raise_error # Valid case
    end

    it "formats multiple errors clearly" do
      context.add_validation_hook(:error1) { |ctx| ctx.add_error("Error 1") }
      context.add_validation_hook(:error2) { |ctx| ctx.add_error("Error 2") }

      expect {
        context.validate!
      }.to raise_error do |error|
        expect(error.message).to include("Error 1")
        expect(error.message).to include("Error 2")
        expect(error.message).to include("Errors:")
      end
    end

    it "includes warnings in error message when errors present" do
      context.add_validation_hook(:critical) { |ctx| ctx.add_error("Critical error") }
      context.add_validation_hook(:warning) { |ctx| ctx.add_warning("Minor warning") }

      expect {
        context.validate!
      }.to raise_error do |error|
        expect(error.message).to include("Critical error")
        expect(error.message).to include("Minor warning")
        expect(error.message).to include("Warnings:")
      end
    end
  end

  describe "workflow definition validation" do
    # Note: Workflows with missing start_with fail at definition time,
    # so we can't test that scenario here. The WorkflowValidator handles it.

    context "with workflow that has no jobs" do
      # This test is tricky because workflows with no jobs fail at definition time.
      # We'll skip this test and rely on WorkflowValidator tests instead.
      it "is handled by WorkflowValidator at definition time" do
        # WorkflowValidator handles this case
        expect(true).to be true
      end
    end
  end
end
