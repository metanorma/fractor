# frozen_string_literal: true

require "spec_helper"
require_relative "../../../examples/workflow/simple_linear/simple_linear_workflow"

RSpec.describe Fractor::Workflow::Builder do
  describe "#initialize" do
    it "creates a new builder with a name" do
      builder = described_class.new("test-workflow")
      expect(builder.name).to eq("test-workflow")
      expect(builder.jobs).to be_empty
    end
  end

  describe "#input_type" do
    it "sets the input type" do
      builder = described_class.new("test")
      builder.input_type(TextData)
      expect(builder.input_type_class).to eq(TextData)
    end

    it "returns self for chaining" do
      builder = described_class.new("test")
      result = builder.input_type(TextData)
      expect(result).to eq(builder)
    end
  end

  describe "#output_type" do
    it "sets the output type" do
      builder = described_class.new("test")
      builder.output_type(FinalOutput)
      expect(builder.output_type_class).to eq(FinalOutput)
    end
  end

  describe "#add_job" do
    it "adds a job to the builder" do
      builder = described_class.new("test")
      builder.add_job("job1", SimpleLinearExample::UppercaseWorker,
                      inputs: :workflow)

      expect(builder.jobs.size).to eq(1)
      expect(builder.jobs.first[:id]).to eq("job1")
      expect(builder.jobs.first[:worker]).to eq(SimpleLinearExample::UppercaseWorker)
    end

    it "returns self for chaining" do
      builder = described_class.new("test")
      result = builder.add_job("job1", SimpleLinearExample::UppercaseWorker)
      expect(result).to eq(builder)
    end

    it "supports adding multiple jobs" do
      builder = described_class.new("test")
      builder.add_job("job1", SimpleLinearExample::UppercaseWorker)
      builder.add_job("job2", SimpleLinearExample::ReverseWorker)

      expect(builder.jobs.size).to eq(2)
    end
  end

  describe "#remove_job" do
    it "removes a job by id" do
      builder = described_class.new("test")
      builder.add_job("job1", SimpleLinearExample::UppercaseWorker)
      builder.add_job("job2", SimpleLinearExample::ReverseWorker)
      builder.remove_job("job1")

      expect(builder.jobs.size).to eq(1)
      expect(builder.jobs.first[:id]).to eq("job2")
    end
  end

  describe "#update_job" do
    it "updates a job's properties" do
      builder = described_class.new("test")
      builder.add_job("job1", SimpleLinearExample::UppercaseWorker)
      builder.update_job("job1", needs: "other_job")

      job = builder.jobs.find { |j| j[:id] == "job1" }
      expect(job[:needs]).to eq("other_job")
    end
  end

  describe "#build" do
    it "builds a workflow class" do
      builder = described_class.new("builder-test")
      builder.input_type(TextData)
      builder.output_type(FinalOutput)
      builder.add_job("uppercase", SimpleLinearExample::UppercaseWorker,
                      inputs: :workflow)
      builder.add_job("reverse", SimpleLinearExample::ReverseWorker,
                      needs: "uppercase", inputs: "uppercase")
      builder.add_job("finalize", SimpleLinearExample::FinalizeWorker,
                      needs: "reverse", inputs: "reverse",
                      outputs_to_workflow: true, terminates: true)

      workflow_class = builder.build

      expect(workflow_class).to be_a(Class)
      expect(workflow_class.workflow_name).to eq("builder-test")
      expect(workflow_class.jobs.keys).to contain_exactly("uppercase",
                                                          "reverse", "finalize")
    end

    it "builds a workflow that can be executed" do
      builder = described_class.new("executable-workflow")
      builder.input_type(TextData)
      builder.output_type(FinalOutput)
      builder.add_job("uppercase", SimpleLinearExample::UppercaseWorker,
                      inputs: :workflow)
      builder.add_job("reverse", SimpleLinearExample::ReverseWorker,
                      needs: "uppercase", inputs: "uppercase")
      builder.add_job("finalize", SimpleLinearExample::FinalizeWorker,
                      needs: "reverse", inputs: "reverse",
                      outputs_to_workflow: true, terminates: true)

      workflow_class = builder.build
      workflow = workflow_class.new
      input = TextData.new(text: "hello")
      result = workflow.execute(input: input)

      expect(result.success?).to be true
      expect(result.output.result).to eq("OLLEH")
    end
  end

  describe "#validate!" do
    it "validates a valid workflow" do
      builder = described_class.new("test")
      builder.add_job("job1", SimpleLinearExample::UppercaseWorker)

      expect { builder.validate! }.not_to raise_error
    end

    it "raises error for empty workflow name" do
      builder = described_class.new("")

      expect do
        builder.validate!
      end.to raise_error(ArgumentError, /must have a name/)
    end

    it "raises error for workflow without jobs" do
      builder = described_class.new("test")

      expect do
        builder.validate!
      end.to raise_error(ArgumentError, /must have at least one job/)
    end

    it "raises error for duplicate job IDs" do
      builder = described_class.new("test")
      builder.add_job("job1", SimpleLinearExample::UppercaseWorker)
      builder.add_job("job1", SimpleLinearExample::ReverseWorker)

      expect do
        builder.validate!
      end.to raise_error(ArgumentError, /Duplicate job IDs/)
    end

    it "raises error for missing dependencies" do
      builder = described_class.new("test")
      builder.add_job("job1", SimpleLinearExample::UppercaseWorker,
                      needs: "nonexistent")

      expect do
        builder.validate!
      end.to raise_error(ArgumentError,
                         /depends on non-existent job/)
    end
  end

  describe "#build!" do
    it "validates and builds the workflow" do
      builder = described_class.new("test")
      builder.add_job("job1", SimpleLinearExample::UppercaseWorker, inputs: :workflow,
                                                                    outputs_to_workflow: true, terminates: true)

      workflow_class = builder.build!
      expect(workflow_class).to be_a(Class)
    end

    it "raises error if validation fails" do
      builder = described_class.new("")

      expect { builder.build! }.to raise_error(ArgumentError)
    end
  end

  describe "#clone" do
    it "creates a copy of the builder" do
      builder = described_class.new("test")
      builder.input_type(TextData)
      builder.add_job("job1", SimpleLinearExample::UppercaseWorker)

      clone = builder.clone

      expect(clone.name).to eq(builder.name)
      expect(clone.jobs.size).to eq(builder.jobs.size)
      expect(clone).not_to equal(builder)
    end
  end
end
