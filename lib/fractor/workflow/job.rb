# frozen_string_literal: true

require_relative "retry_config"

module Fractor
  class Workflow
    # Represents a single job in a workflow.
    # Jobs encapsulate worker configuration, dependencies, and input/output mappings.
    class Job
      attr_reader :name, :workflow_class, :worker_class, :dependencies,
                  :num_workers, :input_mappings, :condition_proc,
                  :terminates, :retry_config, :error_handlers, :fallback_job,
                  :circuit_breaker_config

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
        @retry_config = nil
        @error_handlers = []
        @fallback_job = nil
        @circuit_breaker_config = nil
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

      # Configure retry behavior for this job.
      #
      # @param max_attempts [Integer] Maximum number of retry attempts
      # @param backoff [Symbol] Backoff strategy (:exponential, :linear, :constant, :none)
      # @param initial_delay [Numeric] Initial delay in seconds
      # @param max_delay [Numeric] Maximum delay in seconds
      # @param timeout [Numeric] Job execution timeout in seconds
      # @param retryable_errors [Array<Class>] List of retryable error classes
      # @param options [Hash] Additional retry options
      def retry_on_error(max_attempts: 3, backoff: :exponential,
                         initial_delay: 1, max_delay: nil, timeout: nil,
                         retryable_errors: [StandardError], **options)
        @retry_config = Workflow::RetryConfig.from_options(
          max_attempts: max_attempts,
          backoff: backoff,
          initial_delay: initial_delay,
          max_delay: max_delay,
          timeout: timeout,
          retryable_errors: retryable_errors,
          **options,
        )
      end

      # Add an error handler for this job.
      #
      # @param handler [Proc] A proc that receives (error, context)
      def on_error(&handler)
        unless handler.respond_to?(:call)
          raise ArgumentError, "on_error must be given a block"
        end

        @error_handlers << handler
      end

      # Set a fallback job for this job.
      #
      # @param job_name [String, Symbol] Name of the fallback job
      def fallback_to(job_name)
        @fallback_job = job_name.to_s
      end

      # Configure circuit breaker for this job.
      #
      # @param threshold [Integer] Number of failures before opening circuit
      # @param timeout [Integer] Seconds to wait before trying half-open
      # @param half_open_calls [Integer] Number of test calls in half-open
      # @param shared_key [String] Optional key for shared circuit breaker
      def circuit_breaker(threshold: 5, timeout: 60, half_open_calls: 3,
                          shared_key: nil)
        @circuit_breaker_config = {
          threshold: threshold,
          timeout: timeout,
          half_open_calls: half_open_calls,
          shared_key: shared_key,
        }
      end

      # Check if this job has circuit breaker configured.
      #
      # @return [Boolean] Whether circuit breaker is configured
      def circuit_breaker_enabled?
        !@circuit_breaker_config.nil?
      end

      # Get the circuit breaker key for this job.
      #
      # @return [String] The circuit breaker key
      def circuit_breaker_key
        return nil unless circuit_breaker_enabled?

        @circuit_breaker_config[:shared_key] || "job_#{@name}"
      end

      # Check if this job has retry configured.
      #
      # @return [Boolean] Whether retry is configured
      def retry_enabled?
        !@retry_config.nil? && @retry_config.max_attempts > 1
      end

      # Get the timeout for this job.
      #
      # @return [Numeric, nil] Timeout in seconds or nil
      def timeout
        @retry_config&.timeout
      end

      # Execute error handlers for this job.
      #
      # @param error [Exception] The error that occurred
      # @param context [WorkflowContext] The workflow context
      def handle_error(error, context)
        @error_handlers.each do |handler|
          handler.call(error, context)
        rescue StandardError => e
          context.logger&.error(
            "Error handler failed for job #{@name}: #{e.message}",
          )
        end
      end

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
