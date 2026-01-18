# frozen_string_literal: true

require_relative "workflow/job"
require_relative "workflow/workflow_context"
require_relative "workflow/workflow_executor"
require_relative "workflow/workflow_validator"
require_relative "workflow/job_dependency_validator"
require_relative "workflow/type_compatibility_validator"
require_relative "workflow/execution_strategy"
require_relative "workflow/builder"
require_relative "workflow/chain_builder"
require_relative "workflow/helpers"
require_relative "workflow/logger"
require_relative "workflow/structured_logger"
require_relative "workflow/execution_trace"
require_relative "workflow/visualizer"
require_relative "workflow/dead_letter_queue"
require_relative "workflow/pre_execution_context"
require_relative "workflow/retry_orchestrator"
require_relative "workflow/circuit_breaker_orchestrator"

module Fractor
  # Base class for defining workflows using a declarative DSL.
  # Workflows coordinate multiple jobs with dependencies, type-safe data flow,
  # and support both pipeline and continuous execution modes.
  class Workflow
    class << self
      attr_reader :workflow_name, :workflow_mode, :jobs, :start_job_name,
                  :end_job_names, :input_model_class, :output_model_class,
                  :dlq_config

      # Create a workflow class without inheritance.
      # This is a convenience method that creates an anonymous workflow class.
      #
      # @param name [String] The workflow name
      # @param mode [Symbol] :pipeline (default) or :continuous
      # @yield Block containing job definitions using workflow DSL
      # @return [Class] A new Workflow subclass
      #
      # @example
      #   workflow = Fractor::Workflow.define("my-workflow") do
      #     job "step1", Worker1
      #     job "step2", Worker2, needs: "step1"
      #     job "step3", Worker3, needs: "step2"
      #   end
      #   instance = workflow.new
      #   result = instance.execute(input: data)
      def define(name, mode: :pipeline, &block)
        Class.new(Workflow) do
          workflow(name, mode: mode, &block)
        end
      end

      # Create a linear chain workflow for sequential processing.
      # This provides a fluent API for simple pipelines.
      #
      # @param name [String] The workflow name
      # @return [ChainBuilder] A builder for constructing the chain
      #
      # @example
      #   workflow = Fractor::Workflow.chain("pipeline")
      #     .step("uppercase", UppercaseWorker)
      #     .step("reverse", ReverseWorker)
      #     .step("finalize", FinalizeWorker)
      #     .build
      def chain(name)
        ChainBuilder.new(name)
      end

      # Define a workflow with the given name and optional mode.
      #
      # @param name [String] The workflow name
      # @param mode [Symbol] :pipeline (default) or :continuous
      # @yield Block containing job definitions
      def workflow(name, mode: :pipeline, &block)
        @workflow_name = name
        @workflow_mode = mode
        @jobs = {}
        @start_job_name = nil
        @end_job_names = []
        @input_model_class = nil
        @output_model_class = nil
        @dlq_config = nil

        instance_eval(&block) if block

        validate_workflow!
      end

      # Declare the workflow's input type.
      #
      # @param klass [Class] A Lutaml::Model::Serializable subclass
      def input_type(klass)
        validate_model_class!(klass, "input_type")
        @input_model_class = klass
      end

      # Declare the workflow's output type.
      #
      # @param klass [Class] A Lutaml::Model::Serializable subclass
      def output_type(klass)
        validate_model_class!(klass, "output_type")
        @output_model_class = klass
      end

      # Define the starting job for pipeline mode.
      #
      # @param job_name [String, Symbol] The name of the start job
      def start_with(job_name)
        @start_job_name = job_name.to_s
      end

      # Define an ending job for pipeline mode.
      #
      # @param job_name [String, Symbol] The name of the end job
      # @param on [Symbol] Condition: :success (default), :failure, :cancellation
      def end_with(job_name, on: :success)
        @end_job_names << { name: job_name.to_s, condition: on }
      end

      # Configure the Dead Letter Queue for failed work.
      #
      # @param max_size [Integer] Maximum number of entries to retain
      # @param persister [Object] Optional persistence strategy
      # @param on_add [Proc] Optional callback when entry is added
      def configure_dead_letter_queue(max_size: 1000, persister: nil,
on_add: nil)
        @dlq_config = {
          max_size: max_size,
          persister: persister,
          on_add: on_add,
        }
      end

      # Define a job in the workflow.
      #
      # @param name [String, Symbol] The job name
      # @param worker_class [Class] Optional worker class (shorthand syntax)
      # @param needs [String, Symbol, Array] Optional dependencies (shorthand)
      # @param inputs [Symbol, String, Hash] Optional input configuration (shorthand)
      # @param outputs [Symbol] Optional :workflow to mark outputs (shorthand)
      # @param workers [Integer] Optional parallel worker count (shorthand)
      # @param condition [Proc] Optional conditional execution (shorthand)
      # @yield Block containing job configuration (DSL syntax)
      #
      # @example DSL syntax (original)
      #   job "process" do
      #     runs_with ProcessWorker
      #     needs "validate"
      #   end
      #
      # @example Shorthand syntax (simplified)
      #   job "process", ProcessWorker, needs: "validate"
      #
      # @example Shorthand with multiple options
      #   job "process", ProcessWorker, needs: "validate", outputs: :workflow
      def job(name, worker_class = nil, needs: nil, inputs: nil, outputs: nil,
              workers: nil, condition: nil, &block)
        job_name = name.to_s
        if @jobs.key?(job_name)
          raise ArgumentError,
                "Job '#{job_name}' already defined"
        end

        job_obj = Job.new(job_name, self)

        # Apply shorthand parameters if provided
        if worker_class
          job_obj.runs_with(worker_class)
        end

        if needs
          needs_array = needs.is_a?(Array) ? needs : [needs]
          job_obj.needs(*needs_array)
        end

        if inputs
          case inputs
          when :workflow, "workflow"
            job_obj.inputs_from_workflow
          when String, Symbol
            job_obj.inputs_from_job(inputs.to_s)
          when Hash
            job_obj.inputs_from_multiple(inputs)
          end
        end

        if outputs == :workflow
          job_obj.outputs_to_workflow
        end

        if workers
          job_obj.parallel_workers(workers)
        end

        if condition
          job_obj.if_condition(condition)
        end

        # Apply DSL block if provided
        job_obj.instance_eval(&block) if block

        @jobs[job_name] = job_obj
      end

      # Generate a Mermaid flowchart diagram of the workflow
      #
      # @return [String] Mermaid diagram syntax
      def to_mermaid
        Visualizer.new(self).to_mermaid
      end

      # Generate a DOT/Graphviz diagram of the workflow
      #
      # @return [String] DOT diagram syntax
      def to_dot
        Visualizer.new(self).to_dot
      end

      # Generate an ASCII art diagram of the workflow
      #
      # @return [String] ASCII art representation
      def to_ascii
        Visualizer.new(self).to_ascii
      end

      # Print ASCII diagram to stdout
      def print_diagram
        Visualizer.new(self).print
      end

      private

      def validate_model_class!(klass, method_name)
        # Allow any class - in production you may want stricter validation
        return if klass.is_a?(Class)

        raise ArgumentError, "#{method_name} must be a Class"
      end

      def validate_workflow!
        validator = WorkflowValidator.new(self)
        validator.validate!
      end
    end

    # Create a new workflow instance.
    def initialize(input = nil)
      unless self.class.workflow_name
        raise "Workflow not defined. Use 'workflow \"name\" do ... end' in class definition"
      end

      @workflow_input = input
      @dead_letter_queue = initialize_dead_letter_queue
    end

    # Access the Dead Letter Queue for this workflow.
    #
    # @return [DeadLetterQueue, nil] The DLQ instance or nil if not configured
    def dead_letter_queue
      @dead_letter_queue
    end

    # Execute the workflow with the given input.
    #
    # @param input [Lutaml::Model::Serializable, nil] The workflow input (optional if provided to initialize)
    # @param correlation_id [String] Optional correlation ID for tracking
    # @param logger [Logger] Optional logger instance
    # @param trace [Boolean] Whether to generate execution trace
    # @yield [WorkflowExecutor] Optional block for registering hooks
    # @return [WorkflowResult] The execution result
    def execute(input: nil, correlation_id: nil, logger: nil, trace: false,
&block)
      # Use provided input or fall back to initialization input
      workflow_input = input || @workflow_input
      validate_input!(workflow_input)

      executor = WorkflowExecutor.new(
        self,
        workflow_input,
        correlation_id: correlation_id,
        logger: logger,
        trace: trace,
        dead_letter_queue: @dead_letter_queue,
      )

      # Allow block to register hooks
      block&.call(executor)

      executor.execute
    end

    # Run the workflow in continuous mode with a work queue.
    #
    # @param work_queue [WorkQueue] The queue to receive workflow inputs
    def run_continuous(work_queue:)
      unless self.class.workflow_mode == :continuous
        raise "Workflow '#{self.class.workflow_name}' is not configured for continuous mode"
      end

      # Continuous mode implementation will be added
      raise NotImplementedError, "Continuous mode coming soon"
    end

    private

    def initialize_dead_letter_queue
      config = self.class.dlq_config
      return nil unless config

      dlq = DeadLetterQueue.new(
        max_size: config[:max_size],
        persister: config[:persister],
      )

      # Register callback if provided
      dlq.on_add(&config[:on_add]) if config[:on_add]

      dlq
    end

    def validate_input!(input)
      expected_type = self.class.input_model_class
      return unless expected_type

      unless input.is_a?(expected_type)
        raise TypeError,
              "Workflow '#{self.class.workflow_name}' expects input of type " \
              "#{expected_type}, got #{input.class}"
      end
    end
  end
end
