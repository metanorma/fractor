# frozen_string_literal: true

require_relative "workflow/job"
require_relative "workflow/workflow_context"
require_relative "workflow/workflow_executor"
require_relative "workflow/workflow_validator"
require_relative "workflow/builder"
require_relative "workflow/helpers"
require_relative "workflow/logger"
require_relative "workflow/structured_logger"
require_relative "workflow/execution_trace"
require_relative "workflow/visualizer"

module Fractor
  # Base class for defining workflows using a declarative DSL.
  # Workflows coordinate multiple jobs with dependencies, type-safe data flow,
  # and support both pipeline and continuous execution modes.
  class Workflow
    class << self
      attr_reader :workflow_name, :workflow_mode, :jobs, :start_job_name,
                  :end_job_names, :input_model_class, :output_model_class

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

      # Define a job in the workflow.
      #
      # @param name [String, Symbol] The job name
      # @yield Block containing job configuration
      def job(name, &)
        job_name = name.to_s
        if @jobs.key?(job_name)
          raise ArgumentError,
                "Job '#{job_name}' already defined"
        end

        job_obj = Job.new(job_name, self)
        job_obj.instance_eval(&) if block
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
    def initialize
      unless self.class.workflow_name
        raise "Workflow not defined. Use 'workflow \"name\" do ... end' in class definition"
      end
    end

    # Execute the workflow with the given input.
    #
    # @param input [Lutaml::Model::Serializable] The workflow input
    # @param correlation_id [String] Optional correlation ID for tracking
    # @param logger [Logger] Optional logger instance
    # @param trace [Boolean] Whether to generate execution trace
    # @yield [WorkflowExecutor] Optional block for registering hooks
    # @return [WorkflowResult] The execution result
    def execute(input:, correlation_id: nil, logger: nil, trace: false, &block)
      validate_input!(input)

      executor = WorkflowExecutor.new(
        self,
        input,
        correlation_id: correlation_id,
        logger: logger,
        trace: trace,
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
