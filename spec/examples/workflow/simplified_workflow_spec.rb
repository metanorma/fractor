# frozen_string_literal: true

require "spec_helper"
require_relative "../../../examples/workflow/simplified/simplified_workflow"

RSpec.describe "Simplified Workflow Syntax" do
  let(:input) { TextData.new(text: "test input") }

  describe "ShorthandWorkflow" do
    it "executes successfully with auto-wiring" do
      workflow = ShorthandWorkflow.new
      result = workflow.execute(input: input)

      expect(result.success?).to be true
      expect(result.output).to be_a(FinalOutput)
      expect(result.output.result).to eq("TUPNI TSET")
      expect(result.completed_jobs).to eq(%w[uppercase reverse finalize])
    end

    it "auto-detects start job" do
      expect(ShorthandWorkflow.start_job_name).to eq("uppercase")
    end

    it "auto-detects end jobs" do
      end_job_names = ShorthandWorkflow.end_job_names.map { |ej| ej[:name] }
      expect(end_job_names).to include("finalize")
    end

    it "auto-wires inputs from dependencies" do
      reverse_job = ShorthandWorkflow.jobs["reverse"]
      expect(reverse_job.input_mappings).to have_key("uppercase")
    end
  end

  describe "SimplifiedWorkflow (Workflow.define)" do
    it "creates workflow without inheritance" do
      expect(SimplifiedWorkflow).to be < Fractor::Workflow
      # Note: SimplifiedWorkflow is assigned to a constant, so it has a name
      expect(SimplifiedWorkflow.workflow_name).to eq("simplified-example")
    end

    it "executes successfully" do
      workflow = SimplifiedWorkflow.new
      result = workflow.execute(input: input)

      expect(result.success?).to be true
      expect(result.output.result).to eq("TUPNI TSET")
      expect(result.completed_jobs).to eq(%w[uppercase reverse finalize])
    end

    it "has correct workflow name" do
      expect(SimplifiedWorkflow.workflow_name).to eq("simplified-example")
    end
  end

  describe "ChainWorkflow (Chain API)" do
    it "creates workflow using fluent API" do
      expect(ChainWorkflow).to be < Fractor::Workflow
    end

    it "executes successfully" do
      workflow = ChainWorkflow.new
      result = workflow.execute(input: input)

      expect(result.success?).to be true
      expect(result.output.result).to eq("TUPNI TSET")
      expect(result.completed_jobs).to eq(%w[uppercase reverse finalize])
    end

    it "has correct workflow name" do
      expect(ChainWorkflow.workflow_name).to eq("chain-example")
    end

    it "chains jobs in correct order" do
      jobs = ChainWorkflow.jobs.values
      expect(jobs[0].name).to eq("uppercase")
      expect(jobs[1].name).to eq("reverse")
      expect(jobs[2].name).to eq("finalize")

      expect(jobs[0].dependencies).to be_empty
      expect(jobs[1].dependencies).to eq(["uppercase"])
      expect(jobs[2].dependencies).to eq(["reverse"])
    end
  end

  describe "Comparison with verbose syntax" do
    it "produces identical results across all approaches" do
      inputs = [input]
      results = [
        ShorthandWorkflow.new.execute(input: inputs[0]),
        SimplifiedWorkflow.new.execute(input: inputs[0]),
        ChainWorkflow.new.execute(input: inputs[0]),
      ]

      # All should produce same output
      outputs = results.map { |r| r.output.result }
      expect(outputs.uniq.size).to eq(1)
      expect(outputs.first).to eq("TUPNI TSET")

      # All should complete same jobs
      job_sequences = results.map(&:completed_jobs)
      expect(job_sequences.uniq.size).to eq(1)
    end
  end
end

RSpec.describe "Workflow.chain API" do
  let(:worker1) { SimplifiedExample::UppercaseWorker }
  let(:worker2) { SimplifiedExample::ReverseWorker }
  let(:worker3) { SimplifiedExample::FinalizeWorker }

  describe "ChainBuilder" do
    it "builds valid workflow class" do
      workflow_class = Fractor::Workflow.chain("test-chain")
        .step("step1", worker1)
        .step("step2", worker2)
        .build

      expect(workflow_class).to be < Fractor::Workflow
      expect(workflow_class.workflow_name).to eq("test-chain")
    end

    it "validates chain configuration" do
      builder = Fractor::Workflow.chain("test")

      expect do
        builder.validate!
      end.to raise_error(ArgumentError, /at least one step/)
    end

    it "detects duplicate step names" do
      builder = Fractor::Workflow.chain("test")
        .step("duplicate", worker1)
        .step("duplicate", worker2)

      expect do
        builder.validate!
      end.to raise_error(ArgumentError, /Duplicate step names/)
    end

    it "validates worker classes" do
      expect do
        Fractor::Workflow.chain("test")
          .step("invalid", String)
          .build
      end.to raise_error(ArgumentError, /must inherit from Fractor::Worker/)
    end
  end
end

RSpec.describe "Workflow.define API" do
  it "creates anonymous workflow class" do
    workflow_class = Fractor::Workflow.define("test-workflow") do
      job "step1", SimplifiedExample::UppercaseWorker
    end

    expect(workflow_class).to be < Fractor::Workflow
    expect(workflow_class.workflow_name).to eq("test-workflow")
  end

  it "supports all DSL features" do
    workflow_class = Fractor::Workflow.define("full-featured") do
      input_type TextData
      output_type FinalOutput

      job "step1", SimplifiedExample::UppercaseWorker
      job "step2", SimplifiedExample::ReverseWorker, needs: "step1"
      job "step3", SimplifiedExample::FinalizeWorker, needs: "step2",
                                                      outputs: :workflow
    end

    expect(workflow_class.input_model_class).to eq(TextData)
    expect(workflow_class.output_model_class).to eq(FinalOutput)
    expect(workflow_class.jobs.size).to eq(3)
  end
end

RSpec.describe "Smart auto-wiring" do
  it "auto-wires single dependency" do
    workflow_class = Fractor::Workflow.define("auto-wire-test") do
      job "first", SimplifiedExample::UppercaseWorker
      job "second", SimplifiedExample::ReverseWorker, needs: "first"
    end

    second_job = workflow_class.jobs["second"]
    expect(second_job.input_mappings).to have_key("first")
    expect(second_job.input_mappings["first"]).to eq(:all)
  end

  it "auto-wires workflow input for start jobs" do
    workflow_class = Fractor::Workflow.define("start-job-test") do
      job "start", SimplifiedExample::UppercaseWorker
    end

    start_job = workflow_class.jobs["start"]
    expect(start_job.input_mappings).to have_key(:workflow)
  end

  it "requires explicit configuration for multiple dependencies" do
    expect do
      Fractor::Workflow.define("multi-dep-test") do
        job "a", SimplifiedExample::UppercaseWorker
        job "b", SimplifiedExample::ReverseWorker, needs: "a"
        job "c", SimplifiedExample::FinalizeWorker, needs: %w[a b]
        # Job 'c' has multiple dependencies but no explicit input configuration
      end
    end.to raise_error(Fractor::WorkflowError, /multiple dependencies/)
  end
end

RSpec.describe "Smart defaults" do
  it "auto-detects start job when only one has no dependencies" do
    workflow_class = Fractor::Workflow.define("auto-start") do
      job "first", SimplifiedExample::UppercaseWorker
      job "second", SimplifiedExample::ReverseWorker, needs: "first"
    end

    expect(workflow_class.start_job_name).to eq("first")
  end

  it "auto-detects end jobs (leaf nodes)" do
    workflow_class = Fractor::Workflow.define("auto-end") do
      job "first", SimplifiedExample::UppercaseWorker
      job "second", SimplifiedExample::ReverseWorker, needs: "first"
      job "third", SimplifiedExample::FinalizeWorker, needs: "second"
    end

    end_job_names = workflow_class.end_job_names.map { |ej| ej[:name] }
    expect(end_job_names).to include("third")

    third_job = workflow_class.jobs["third"]
    expect(third_job.outputs_to_workflow?).to be true
    expect(third_job.terminates).to be true
  end

  it "requires explicit start_with when multiple start jobs exist" do
    expect do
      Fractor::Workflow.define("multi-start") do
        job "a", SimplifiedExample::UppercaseWorker
        job "b", SimplifiedExample::ReverseWorker
      end
    end.to raise_error(Fractor::WorkflowError, /must define start_with/)
  end
end

RSpec.describe "Shorthand job syntax" do
  it "supports worker class as second parameter" do
    workflow_class = Fractor::Workflow.define("shorthand-worker") do
      job "process", SimplifiedExample::UppercaseWorker
    end

    job = workflow_class.jobs["process"]
    expect(job.worker_class).to eq(SimplifiedExample::UppercaseWorker)
  end

  it "supports needs parameter" do
    workflow_class = Fractor::Workflow.define("shorthand-needs") do
      job "first", SimplifiedExample::UppercaseWorker
      job "second", SimplifiedExample::ReverseWorker, needs: "first"
    end

    job = workflow_class.jobs["second"]
    expect(job.dependencies).to eq(["first"])
  end

  it "supports inputs parameter with :workflow" do
    workflow_class = Fractor::Workflow.define("shorthand-inputs-workflow") do
      job "process", SimplifiedExample::UppercaseWorker, inputs: :workflow
    end

    job = workflow_class.jobs["process"]
    expect(job.input_mappings).to have_key(:workflow)
  end

  it "supports inputs parameter with job name" do
    workflow_class = Fractor::Workflow.define("shorthand-inputs-job") do
      job "first", SimplifiedExample::UppercaseWorker
      job "second", SimplifiedExample::ReverseWorker, needs: "first",
                                                      inputs: "first"
    end

    job = workflow_class.jobs["second"]
    expect(job.input_mappings).to have_key("first")
  end

  it "supports outputs parameter" do
    workflow_class = Fractor::Workflow.define("shorthand-outputs") do
      job "process", SimplifiedExample::UppercaseWorker, outputs: :workflow
    end

    job = workflow_class.jobs["process"]
    expect(job.outputs_to_workflow?).to be true
  end

  it "supports workers parameter" do
    workflow_class = Fractor::Workflow.define("shorthand-parallel") do
      job "process", SimplifiedExample::UppercaseWorker, workers: 3
    end

    job = workflow_class.jobs["process"]
    expect(job.num_workers).to eq(3)
  end

  it "supports condition parameter" do
    condition_proc = ->(_ctx) { true }

    workflow_class = Fractor::Workflow.define("shorthand-condition") do
      job "process", SimplifiedExample::UppercaseWorker,
          condition: condition_proc
    end

    job = workflow_class.jobs["process"]
    expect(job.condition_proc).to eq(condition_proc)
  end

  it "supports combined shorthand parameters" do
    workflow_class = Fractor::Workflow.define("shorthand-combined") do
      job "first", SimplifiedExample::UppercaseWorker, inputs: :workflow
      job "second", SimplifiedExample::ReverseWorker,
          needs: "first",
          workers: 2,
          outputs: :workflow
    end

    second_job = workflow_class.jobs["second"]
    expect(second_job.dependencies).to eq(["first"])
    expect(second_job.num_workers).to eq(2)
    expect(second_job.outputs_to_workflow?).to be true
  end

  it "allows mixing shorthand with DSL block" do
    workflow_class = Fractor::Workflow.define("mixed-syntax") do
      job "validate", SimplifiedExample::UppercaseWorker
      job "process", SimplifiedExample::ReverseWorker, needs: "validate" do
        parallel_workers 3
      end
    end

    job = workflow_class.jobs["process"]
    expect(job.worker_class).to eq(SimplifiedExample::ReverseWorker)
    expect(job.dependencies).to eq(["validate"])
    expect(job.num_workers).to eq(3)
  end
end
