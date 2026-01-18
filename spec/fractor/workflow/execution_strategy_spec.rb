# frozen_string_literal: true

require "spec_helper"

# Test worker for the workflow - must be defined before workflow_class
class ExecutionStrategyTestWorker < Fractor::Worker
  input_type String
  output_type String

  def process(work)
    Fractor::WorkResult.new(result: work.input.upcase, work: work)
  end
end

RSpec.describe Fractor::Workflow::ExecutionStrategy do
  let(:workflow_class) do
    Class.new(Fractor::Workflow) do
      workflow "test_workflow" do
        input_type String
        output_type String

        start_with "process"

        job "process" do
          runs_with ExecutionStrategyTestWorker
          inputs_from_workflow
          outputs_to_workflow
          terminates_workflow
        end
      end
    end
  end

  let(:input) { "test input" }
  let(:workflow) { workflow_class.new }
  let(:executor) do
    Fractor::Workflow::WorkflowExecutor.new(workflow, input)
  end

  describe "#initialize" do
    it "stores the executor and debug flag" do
      strategy = described_class.new(executor, debug: true)
      expect(strategy.executor).to eq(executor)
      expect(strategy.debug).to be true
    end
  end

  describe "#execute" do
    it "raises NotImplementedError for base class" do
      strategy = described_class.new(executor)
      job_group = workflow.class.jobs.values

      expect do
        strategy.execute(job_group)
      end.to raise_error(NotImplementedError, /must implement #execute/)
    end
  end

  describe "#should_execute_job?" do
    it "returns true for jobs without conditions" do
      job = workflow.class.jobs["process"]
      strategy = described_class.new(executor)

      expect(strategy.should_execute_job?(job)).to be true
    end

    it "evaluates the job's condition proc if present" do
      workflow_with_condition = Class.new(Fractor::Workflow) do
        workflow "conditional" do
          input_type String
          output_type String
          start_with "process"

          job "process" do
            runs_with ExecutionStrategyTestWorker
            inputs_from_workflow
            if_condition ->(_ctx) { false }
            outputs_to_workflow
            terminates_workflow
          end
        end
      end

      job = workflow_with_condition.jobs["process"]
      strategy = described_class.new(executor)

      expect(strategy.should_execute_job?(job)).to be false
    end
  end
end

RSpec.describe Fractor::Workflow::SequentialExecutionStrategy do
  let(:workflow_class) do
    Class.new(Fractor::Workflow) do
      workflow "test_workflow" do
        input_type String
        output_type String
        start_with "process"
        end_with "process"

        job "process" do
          runs_with ExecutionStrategyTestWorker
          inputs_from_workflow
          outputs_to_workflow
          terminates_workflow
        end
      end
    end
  end

  let(:input) { "test input" }
  let(:workflow) { workflow_class.new }
  let(:executor) { Fractor::Workflow::WorkflowExecutor.new(workflow, input) }

  class ExecutionStrategyTestWorker < Fractor::Worker
    input_type String
    output_type String

    def process(work)
      Fractor::WorkResult.new(result: work.input.upcase, work: work)
    end
  end

  describe "#execute" do
    it "executes jobs sequentially" do
      strategy = described_class.new(executor)
      job_group = workflow.class.jobs.values

      result = strategy.execute(job_group)

      expect(result).to be true
      expect(executor.completed_jobs).to include("process")
    end
  end
end

RSpec.describe Fractor::Workflow::ParallelExecutionStrategy do
  let(:workflow_class) do
    Class.new(Fractor::Workflow) do
      workflow "test_workflow" do
        input_type String
        output_type String
        start_with "process"
        end_with "process"

        job "process" do
          runs_with ExecutionStrategyTestWorker
          inputs_from_workflow
          outputs_to_workflow
          terminates_workflow
        end
      end
    end
  end

  let(:input) { "test input" }
  let(:workflow) { workflow_class.new }
  let(:executor) { Fractor::Workflow::WorkflowExecutor.new(workflow, input) }

  class ExecutionStrategyTestWorker < Fractor::Worker
    input_type String
    output_type String

    def process(work)
      Fractor::WorkResult.new(result: work.input.upcase, work: work)
    end
  end

  describe "#execute" do
    it "executes jobs in parallel" do
      strategy = described_class.new(executor)
      job_group = workflow.class.jobs.values

      result = strategy.execute(job_group)

      expect(result).to be true
    end
  end
end

RSpec.describe Fractor::Workflow::PipelineExecutionStrategy do
  let(:workflow_class) do
    Class.new(Fractor::Workflow) do
      workflow "test_workflow" do
        input_type String
        output_type String
        start_with "process"
        end_with "process"

        job "process" do
          runs_with ExecutionStrategyTestWorker
          inputs_from_workflow
          outputs_to_workflow
          terminates_workflow
        end
      end
    end
  end

  let(:input) { "test input" }
  let(:workflow) { workflow_class.new }
  let(:executor) { Fractor::Workflow::WorkflowExecutor.new(workflow, input) }

  class ExecutionStrategyTestWorker < Fractor::Worker
    input_type String
    output_type String

    def process(work)
      Fractor::WorkResult.new(result: work.input.upcase, work: work)
    end
  end

  describe "#execute" do
    it "executes a single job as pipeline" do
      strategy = described_class.new(executor)
      job_group = workflow.class.jobs.values

      result = strategy.execute(job_group)

      expect(result).to be true
    end

    it "raises error if more than one job in group" do
      workflow_with_two = Class.new(Fractor::Workflow) do
        workflow "two_jobs" do
          input_type String
          output_type String
          start_with "job1"

          job "job1" do
            runs_with ExecutionStrategyTestWorker
            inputs_from_workflow
          end

          job "job2" do
            runs_with ExecutionStrategyTestWorker
            needs "job1"
            inputs_from_job "job1"
            outputs_to_workflow
            terminates_workflow
          end
        end
      end

      strategy = described_class.new(executor)
      job_group = workflow_with_two.jobs.values.to_a

      expect do
        strategy.execute(job_group)
      end.to raise_error(Fractor::WorkflowError,
                         /Pipeline strategy expects exactly 1 job/)
    end
  end
end
