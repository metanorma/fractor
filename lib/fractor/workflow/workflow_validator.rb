# frozen_string_literal: true

require "set"

module Fractor
  class Workflow
    # Validates workflow structure and configuration.
    # Checks for cycles, missing dependencies, type compatibility, and proper entry/exit points.
    #
    # This validator integrates JobDependencyValidator and TypeCompatibilityValidator
    # to provide comprehensive validation with detailed error messages.
    class WorkflowValidator
      attr_reader :workflow_class

      def initialize(workflow_class)
        @workflow_class = workflow_class
      end

      # Validate the workflow structure.
      # Raises appropriate errors if validation fails.
      def validate!
        validate_basic_structure!
        apply_smart_defaults!
        auto_wire_job_inputs!

        # Use new validators for better error messages
        validate_dependencies_with_new_validator!
        validate_type_compatibility!

        validate_entry_exit_points! unless continuous_mode?
        validate_job_workers!
        validate_input_mappings!
      end

      private

      def continuous_mode?
        @workflow_class.workflow_mode == :continuous
      end

      def validate_basic_structure!
        if @workflow_class.jobs.empty?
          raise WorkflowError,
                "Workflow '#{@workflow_class.workflow_name}' has no jobs defined.\n\n" \
                "A workflow must define at least one job using the `job` DSL method:\n\n" \
                "  workflow '#{@workflow_class.workflow_name}' do\n" \
                "    job 'process' do\n" \
                "      runs_with MyWorker\n" \
                "      inputs_from_workflow\n" \
                "      outputs_to_workflow\n" \
                "    end\n" \
                "  end"
        end
      end

      # Apply smart defaults for start/end jobs if not explicitly configured
      def apply_smart_defaults!
        return if continuous_mode?

        # Auto-detect start job if not specified
        unless @workflow_class.start_job_name
          start_jobs = @workflow_class.jobs.values.select do |job|
            job.dependencies.empty?
          end

          if start_jobs.size == 1
            @workflow_class.instance_variable_set(:@start_job_name,
                                                  start_jobs.first.name)
          end
        end

        # Auto-detect end jobs if not specified
        if @workflow_class.end_job_names.empty?
          # Find jobs with no dependents (leaf jobs)
          all_dependencies = @workflow_class.jobs.values.flat_map(&:dependencies).to_set
          end_job_candidates = @workflow_class.jobs.keys.reject do |job_name|
            all_dependencies.include?(job_name)
          end

          end_job_candidates.each do |job_name|
            job = @workflow_class.jobs[job_name]
            job.outputs_to_workflow
            job.terminates_workflow
            @workflow_class.end_job_names << { name: job_name,
                                               condition: :success }
          end
        end
      end

      # Auto-wire job inputs based on dependencies
      def auto_wire_job_inputs!
        @workflow_class.jobs.each_value(&:auto_wire_inputs!)
      end

      # Validate dependencies using JobDependencyValidator for better error messages.
      def validate_dependencies_with_new_validator!
        jobs = @workflow_class.jobs.values
        validator = JobDependencyValidator.new(jobs)

        begin
          validator.validate!
        rescue JobDependencyValidator::DependencyError => e
          # Convert to WorkflowError with additional context
          raise WorkflowError,
                "Workflow '#{@workflow_class.workflow_name}' has dependency issues:\n\n" \
                "#{e.message}\n\n" \
                "Fix: Ensure all job dependencies exist and there are no circular dependencies."
        end
      end

      # Validate type compatibility between connected jobs.
      def validate_type_compatibility!
        jobs = @workflow_class.jobs.values
        validator = TypeCompatibilityValidator.new(jobs)

        issues = validator.check_compatibility_between_jobs
        return if issues.empty?

        # Build detailed error message
        error_lines = ["Workflow '#{@workflow_class.workflow_name}' has type compatibility issues:\n"]

        issues.each do |issue|
          error_lines << "  Job '#{issue[:consumer]}' depends on '#{issue[:producer]}'"
          error_lines << "    Producer output type: #{issue[:producer_type]}"
          error_lines << "    Consumer input type: #{issue[:consumer_type]}"
          error_lines << "    Suggestion: #{issue[:suggestion]}"
          error_lines << ""
        end

        error_lines << "Fix: Ensure compatible types between connected jobs."

        raise WorkflowError, error_lines.join("\n")
      end

      def validate_entry_exit_points!
        # Pipeline mode requires start_with and end_with
        unless @workflow_class.start_job_name
          raise WorkflowError,
                "Pipeline workflow '#{@workflow_class.workflow_name}' must define start_with.\n\n" \
                "Add a start job to your workflow:\n\n" \
                "  workflow '#{@workflow_class.workflow_name}' do\n" \
                "    start_with 'process'  # Define the starting job\n" \
                "    job 'process' do\n" \
                "      runs_with MyWorker\n" \
                "      # ...\n" \
                "    end\n" \
                "  end"
        end

        if @workflow_class.end_job_names.empty?
          raise WorkflowError,
                "Pipeline workflow '#{@workflow_class.workflow_name}' must define at least one end_with.\n\n" \
                "Add an end job to your workflow:\n\n" \
                "  workflow '#{@workflow_class.workflow_name}' do\n" \
                "    # ...\n" \
                "    end_with 'finalize'  # Define the ending job\n" \
                "    job 'finalize' do\n" \
                "      runs_with FinalizeWorker\n" \
                "      outputs_to_workflow\n" \
                "      terminates_workflow\n" \
                "    end\n" \
                "  end"
        end

        # Verify start job exists
        unless @workflow_class.jobs.key?(@workflow_class.start_job_name)
          raise WorkflowError,
                "Start job '#{@workflow_class.start_job_name}' not defined in workflow.\n\n" \
                "Available jobs: #{@workflow_class.jobs.keys.join(', ')}\n\n" \
                "Fix: Define the missing job or correct the start_with name."
        end

        # Verify end jobs exist
        @workflow_class.end_job_names.each do |end_job_spec|
          job_name = end_job_spec[:name]
          unless @workflow_class.jobs.key?(job_name)
            raise WorkflowError,
                  "End job '#{job_name}' not defined in workflow.\n\n" \
                  "Available jobs: #{@workflow_class.jobs.keys.join(', ')}\n\n" \
                  "Fix: Define the missing job or correct the end_with name."
          end
        end

        # Verify all jobs are reachable from start
        validate_reachability!
      end

      def validate_job_workers!
        @workflow_class.jobs.each do |name, job|
          unless job.worker_class
            raise WorkflowError,
                  "Job '#{name}' does not specify a worker class.\n\n" \
                  "Add a worker using runs_with:\n\n" \
                  "  job '#{name}' do\n" \
                  "    runs_with MyWorker  # Specify the worker class\n" \
                  "  end"
          end

          unless job.input_type
            raise WorkflowError,
                  "Job '#{name}' worker '#{job.worker_class}' does not declare input_type.\n\n" \
                  "Add input_type to your worker:\n\n" \
                  "  class #{job.worker_class} < Fractor::Worker\n" \
                  "    input_type MyInputClass\n" \
                  "    output_type MyOutputClass\n" \
                  "  end"
          end

          unless job.output_type
            raise WorkflowError,
                  "Job '#{name}' worker '#{job.worker_class}' does not declare output_type.\n\n" \
                  "Add output_type to your worker:\n\n" \
                  "  class #{job.worker_class} < Fractor::Worker\n" \
                  "    input_type MyInputClass\n" \
                  "    output_type MyOutputClass\n" \
                  "  end"
          end
        end
      end

      def validate_input_mappings!
        @workflow_class.jobs.each do |name, job|
          # After auto-wiring, all jobs should have input mappings
          if job.input_mappings.empty?
            if job.dependencies.size > 1
              raise WorkflowError,
                    "Job '#{name}' has multiple dependencies (#{job.dependencies.join(', ')}). " \
                    "Please explicitly configure inputs using inputs_from_job or inputs_from_multiple"
            else
              raise WorkflowError,
                    "Job '#{name}' has no input mappings configured"
            end
          end

          # Validate source jobs exist in mappings
          job.input_mappings.each_key do |source|
            next if source == :workflow

            unless @workflow_class.jobs.key?(source)
              raise WorkflowError,
                    "Job '#{name}' maps inputs from '#{source}' which is not defined"
            end
          end
        end
      end

      def validate_reachability!
        start_job = @workflow_class.start_job_name
        reachable = compute_reachable_jobs(start_job)

        unreachable = @workflow_class.jobs.keys.to_set - reachable
        return if unreachable.empty?

        raise WorkflowError,
              "Unreachable jobs detected: #{unreachable.to_a.join(', ')}. " \
              "All jobs must be reachable from start_with job '#{start_job}'"
      end

      def compute_reachable_jobs(start_job)
        reachable = Set.new
        queue = [start_job]

        until queue.empty?
          current = queue.shift
          next if reachable.include?(current)

          reachable.add(current)

          # Find jobs that depend on current job
          @workflow_class.jobs.each do |name, job|
            # Follow explicit dependencies
            if job.dependencies.include?(current) && !reachable.include?(name)
              queue << name
            end

            # Follow fallback relationships from current job
            if current == name && job.fallback_job && !reachable.include?(job.fallback_job)
              queue << job.fallback_job
            end
          end
        end

        reachable
      end
    end
  end

  # Custom error classes
  class WorkflowError < StandardError; end
  class WorkflowCycleError < WorkflowError; end
  class WorkflowValidationError < WorkflowError; end
  class InputMismatchError < WorkflowError; end
  class OutputMismatchError < WorkflowError; end
  class WorkflowExecutionError < WorkflowError; end
end
