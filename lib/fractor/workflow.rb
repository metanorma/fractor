# frozen_string_literal: true

require_relative "workflow/job"
require_relative "workflow/workflow_context"
require_relative "workflow/workflow_executor"
require_relative "workflow/workflow_validator"
require_relative "workflow/builder"
require_relative "workflow/helpers"

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

        instance_eval(&block) if block_given?

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
      def job(name, &block)
        job_name = name.to_s
        raise ArgumentError, "Job '#{job_name}' already defined" if @jobs.key?(job_name)

        job_obj = Job.new(job_name, self)
        job_obj.instance_eval(&block) if block_given?
        @jobs[job_name] = job_obj
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
    # @return [WorkflowResult] The execution result
    def execute(input:)
      validate_input!(input)

      executor = WorkflowExecutor.new(self, input)
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
