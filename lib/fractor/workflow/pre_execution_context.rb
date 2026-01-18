# frozen_string_literal: true

module Fractor
  class Workflow
    # Manages pre-execution validation for workflows.
    # Provides hooks for custom validation logic and detailed error messages.
    #
    # This class ensures workflows are validated with full context before
    # execution begins, catching errors early with clear messages.
    class PreExecutionContext
      attr_reader :workflow, :input, :errors, :warnings

      def initialize(workflow, input)
        @workflow = workflow
        @input = input
        @errors = []
        @warnings = []
        @validation_hooks = []
      end

      # Register a custom validation hook.
      # Hooks should return true if validation passes, or add error messages.
      #
      # @param name [String, Symbol] Optional name for the validation
      # @yield [context] Block that receives the pre-execution context
      #
      # @example Add custom validation
      #   context.add_validation_hook(:check_api_key) do |ctx|
      #     unless ctx.input.api_key
      #       ctx.add_error("API key is required")
      #     end
      #   end
      def add_validation_hook(name = nil, &block)
        unless block_given?
          raise ArgumentError, "Must provide a block for validation hook"
        end

        @validation_hooks << { name: name, block: block }
      end

      # Run all validations and return whether validation passed.
      #
      # @return [Boolean] true if all validations pass
      # @raise [WorkflowError] if validation fails
      def validate!
        reset_results

        # Run built-in validations
        validate_workflow_definition!
        validate_input_type!
        validate_input_presence!

        # Run custom validation hooks
        run_validation_hooks

        # Raise error if any validation failed
        unless @errors.empty?
          raise WorkflowError, validation_error_message
        end

        # Log warnings if any
        log_warnings unless @warnings.empty?

        true
      end

      # Add an error message to the validation context.
      #
      # @param message [String] The error message
      def add_error(message)
        @errors << message
      end

      # Add a warning message to the validation context.
      #
      # @param message [String] The warning message
      def add_warning(message)
        @warnings << message
      end

      # Check if validation passed (errors only).
      #
      # @return [Boolean] true if no errors
      def valid?
        @errors.empty?
      end

      # Check if there are any warnings (regardless of errors).
      #
      # @return [Boolean] true if warnings present
      def has_warnings?
        !@warnings.empty?
      end

      private

      def reset_results
        @errors = []
        @warnings = []
      end

      def validate_workflow_definition!
        # Ensure workflow is properly defined
        workflow_class = @workflow.class

        if workflow_class.jobs.empty?
          add_error("Workflow '#{workflow_class.workflow_name}' has no jobs defined")
        end

        # Check for start job in pipeline mode
        if workflow_class.workflow_mode == :pipeline && !workflow_class.start_job_name
          add_error("Pipeline workflow must define start_with")
        end
      end

      def validate_input_type!
        expected_type = @workflow.class.input_model_class
        return unless expected_type

        unless @input.is_a?(expected_type)
          add_error(
            "Workflow '#{@workflow.class.workflow_name}' expects input of type " \
            "#{expected_type}, got #{@input.class}"
          )
        end
      end

      def validate_input_presence!
        return if @input

        # Check if workflow requires input
        if @workflow.class.input_model_class || requires_workflow_input?
          add_error(
            "Workflow '#{@workflow.class.workflow_name}' requires input but none was provided"
          )
        end
      end

      def requires_workflow_input?
        # Check if any job takes input from workflow
        @workflow.class.jobs.values.any? do |job|
          job.input_mappings.key?(:workflow)
        end
      end

      def run_validation_hooks
        @validation_hooks.each do |hook|
          begin
            hook[:block].call(self)
          rescue StandardError => e
            add_error(
              "Validation hook '#{hook[:name] || 'unnamed'}' raised error: #{e.message}"
            )
          end
        end
      end

      def validation_error_message
        workflow_name = @workflow.class.workflow_name

        lines = [
          "Workflow '#{workflow_name}' validation failed",
          "",
          "Errors:"
        ]

        @errors.each_with_index do |error, index|
          lines << "  #{index + 1}. #{error}"
        end

        unless @warnings.empty?
          lines << ""
          lines << "Warnings:"
          @warnings.each_with_index do |warning, index|
            lines << "  #{index + 1}. #{warning}"
          end
        end

        lines << ""
        lines << "Fix: Address the errors above before executing the workflow."

        lines.join("\n")
      end

      def log_warnings
        workflow_name = @workflow.class.workflow_name

        $stderr.puts "Workflow '#{workflow_name}' validation warnings:"
        @warnings.each_with_index do |warning, index|
          $stderr.puts "  #{index + 1}. #{warning}"
        end
      end
    end
  end
end
