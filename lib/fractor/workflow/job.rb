# frozen_string_literal: true

module Fractor
  class Workflow
    # Represents a single job in a workflow.
    # Jobs encapsulate worker configuration, dependencies, and input/output mappings.
    class Job
      attr_reader :name, :workflow_class, :worker_class, :dependencies,
                  :num_workers, :input_mappings, :condition_proc,
                  :terminates

      def initialize(name, workflow_class)
        @name = name
        @workflow_class = workflow_class
        @worker_class = nil
        @dependencies = []
        @num_workers = nil
        @input_mappings = {}
        @condition_proc = nil
        @terminates = false
        @outputs_to_workflow = false
        @state = :pending
      end

      # Specify which worker class processes this job.
      #
      # @param klass [Class] A Fractor::Worker subclass
      def runs_with(klass)
        unless klass < Fractor::Worker
          raise ArgumentError, "#{klass} must inherit from Fractor::Worker"
        end

        @worker_class = klass
      end

      # Specify job dependencies.
      #
      # @param job_names [Array<String, Symbol>] Names of jobs this job depends on
      def needs(*job_names)
        @dependencies = job_names.flatten.map(&:to_s)
      end

      # Set the number of parallel workers for this job.
      #
      # @param n [Integer] Number of workers
      def parallel_workers(n)
        unless n.is_a?(Integer) && n.positive?
          raise ArgumentError, "parallel_workers must be a positive integer"
        end

        @num_workers = n
      end

      # Map inputs from the workflow input.
      # Used when this is the first job in the workflow.
      def inputs_from_workflow
        @input_mappings[:workflow] = true
      end
      alias inputs_from :inputs_from_workflow

      # Auto-wire inputs from dependencies if not explicitly configured.
      # Called during workflow finalization.
      def auto_wire_inputs!
        return unless @input_mappings.empty?

        if @dependencies.empty?
          # No dependencies = must be a start job
          @input_mappings[:workflow] = true
        elsif @dependencies.size == 1
          # Single dependency = auto-wire from that job
          @input_mappings[@dependencies.first] = :all
        end
        # Multiple dependencies require explicit configuration
      end

      # Map inputs from a single upstream job.
      #
      # @param source_job [String, Symbol] The source job name
      # @param select [Hash] Optional attribute mappings
      def inputs_from_job(source_job, select: nil)
        source = source_job.to_s
        @input_mappings[source] = select || :all
      end

      # Map inputs from multiple upstream jobs.
      #
      # @param mappings [Hash] Hash of source_job => attribute_mappings
      # Example:
      #   inputs_from_multiple(
      #     "job_a" => { validated_data: :validated_data },
      #     "job_b" => { analysis: :results }
      #   )
      def inputs_from_multiple(mappings)
        mappings.each do |source_job, attr_mappings|
          source = source_job.to_s
          @input_mappings[source] = attr_mappings
        end
      end

      # Set a condition for this job to run.
      #
      # @param proc [Proc] A proc that receives the workflow context
      def if_condition(proc)
        unless proc.respond_to?(:call)
          raise ArgumentError, "if_condition must be callable"
        end

        @condition_proc = proc
      end

      # Mark this job as a workflow terminator.
      #
      # @param value [Boolean] Whether this job terminates the workflow
      def terminates_workflow(value = true)
        @terminates = value
      end

      # Mark this job's outputs as mapping to workflow outputs.
      def outputs_to_workflow
        @outputs_to_workflow = true
      end
      alias outputs_to :outputs_to_workflow

      # Check if this job's outputs map to workflow outputs.
      #
      # @return [Boolean] Whether this job outputs to workflow
      def outputs_to_workflow?
        @outputs_to_workflow
      end

      # Check if this job should execute based on its condition.
      #
      # @param context [WorkflowContext] The workflow execution context
      # @return [Boolean] Whether the job should execute
      def should_execute?(context)
        return true unless @condition_proc

        @condition_proc.call(context)
      end

      # Get the input type for this job from its worker.
      #
      # @return [Class] The input type class
      def input_type
        return nil unless @worker_class

        @worker_class.input_type_class
      end

      # Get the output type for this job from its worker.
      #
      # @return [Class] The output type class
      def output_type
        return nil unless @worker_class

        @worker_class.output_type_class
      end

      # Check if this job is ready to execute.
      # A job is ready when all its dependencies have completed.
      #
      # @param completed_jobs [Set] Set of completed job names
      # @return [Boolean] Whether the job is ready
      def ready?(completed_jobs)
        @dependencies.all? { |dep| completed_jobs.include?(dep) }
      end

      # Get or set the job state.
      #
      # @param new_state [Symbol] :pending, :ready, :running, :completed, :failed, :skipped
      # @return [Symbol] The current state
      def state(new_state = nil)
        @state = new_state if new_state
        @state
      end

      def to_s
        "Job[#{@name}]"
      end
    end
  end
end
