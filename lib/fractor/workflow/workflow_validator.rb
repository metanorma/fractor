# frozen_string_literal: true

require "set"

module Fractor
  class Workflow
    # Validates workflow structure and configuration.
    # Checks for cycles, missing dependencies, type compatibility, and proper entry/exit points.
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
        validate_entry_exit_points! unless continuous_mode?
        validate_job_workers!
        validate_dependencies!
        detect_cycles!
        validate_input_mappings!
      end

      private

      def continuous_mode?
        @workflow_class.workflow_mode == :continuous
      end

      def validate_basic_structure!
        if @workflow_class.jobs.empty?
          raise WorkflowError,
                "Workflow '#{@workflow_class.workflow_name}' has no jobs defined"
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
        @workflow_class.jobs.each_value do |job|
          job.auto_wire_inputs!
        end
      end

      def validate_entry_exit_points!
        # Pipeline mode requires start_with and end_with
        unless @workflow_class.start_job_name
          raise WorkflowError,
                "Pipeline workflow '#{@workflow_class.workflow_name}' must define start_with"
        end

        if @workflow_class.end_job_names.empty?
          raise WorkflowError,
                "Pipeline workflow '#{@workflow_class.workflow_name}' must define at least one end_with"
        end

        # Verify start job exists
        unless @workflow_class.jobs.key?(@workflow_class.start_job_name)
          raise WorkflowError,
                "Start job '#{@workflow_class.start_job_name}' not defined in workflow"
        end

        # Verify end jobs exist
        @workflow_class.end_job_names.each do |end_job_spec|
          job_name = end_job_spec[:name]
          unless @workflow_class.jobs.key?(job_name)
            raise WorkflowError,
                  "End job '#{job_name}' not defined in workflow"
          end
        end

        # Verify all jobs are reachable from start
        validate_reachability!
      end

      def validate_job_workers!
        @workflow_class.jobs.each do |name, job|
          unless job.worker_class
            raise WorkflowError,
                  "Job '#{name}' does not specify a worker class (use runs_with)"
          end

          unless job.input_type
            raise WorkflowError,
                  "Job '#{name}' worker '#{job.worker_class}' does not declare input_type"
          end

          unless job.output_type
            raise WorkflowError,
                  "Job '#{name}' worker '#{job.worker_class}' does not declare output_type"
          end
        end
      end

      def validate_dependencies!
        @workflow_class.jobs.each do |name, job|
          job.dependencies.each do |dep_name|
            unless @workflow_class.jobs.key?(dep_name)
              raise WorkflowError,
                    "Job '#{name}' depends on '#{dep_name}' which is not defined"
            end
          end
        end
      end

      def detect_cycles!
        visited = Set.new
        rec_stack = Set.new

        @workflow_class.jobs.each_key do |job_name|
          if has_cycle?(job_name, visited, rec_stack)
            raise WorkflowCycleError,
                  "Cycle detected involving job '#{job_name}'. " \
                  "Workflows cannot have circular dependencies"
          end
        end
      end

      def has_cycle?(job_name, visited, rec_stack)
        return false if visited.include?(job_name)

        visited.add(job_name)
        rec_stack.add(job_name)

        job = @workflow_class.jobs[job_name]
        job.dependencies.each do |dep_name|
          if !visited.include?(dep_name) && has_cycle?(dep_name, visited,
                                                       rec_stack)
            return true
          elsif rec_stack.include?(dep_name)
            return true
          end
        end

        rec_stack.delete(job_name)
        false
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
            if job.dependencies.include?(current) && !reachable.include?(name)
              queue << name
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
