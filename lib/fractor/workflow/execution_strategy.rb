# frozen_string_literal: true

module Fractor
  class Workflow
    # Base class for workflow execution strategies.
    # Defines the interface for different execution patterns.
    #
    # @abstract Subclasses must implement the `execute` method
    class ExecutionStrategy
      attr_reader :executor, :debug

      # Initialize a new execution strategy.
      #
      # @param executor [WorkflowExecutor] The workflow executor
      # @param debug [Boolean] Whether to enable debug logging
      def initialize(executor, debug: false)
        @executor = executor
        @debug = debug
      end

      # Execute a group of jobs according to the strategy.
      #
      # @param job_group [Array<Job>] Jobs to execute
      # @return [Boolean] true if execution should continue
      # @raise [WorkflowError] if execution fails
      def execute(job_group)
        raise NotImplementedError, "#{self.class} must implement #execute"
      end

      # Check if a job should be executed based on its condition.
      #
      # @param job [Job] The job to check
      # @return [Boolean] true if the job should execute
      def should_execute_job?(job)
        return true unless job.condition_proc

        job.condition_proc.call(executor.context)
      end

      protected

      # Get the workflow instance.
      #
      # @return [Workflow] The workflow
      def workflow
        executor.workflow
      end

      # Get the workflow context.
      #
      # @return [WorkflowContext] The context
      def context
        executor.context
      end

      # Get the execution hooks.
      #
      # @return [ExecutionHooks] The hooks
      def hooks
        executor.hooks
      end

      # Get the execution trace.
      #
      # @return [ExecutionTrace, nil] The trace or nil
      def trace
        executor.trace
      end

      # Get the dead letter queue.
      #
      # @return [DeadLetterQueue, nil] The DLQ or nil
      def dead_letter_queue
        executor.dead_letter_queue
      end

      # Log a debug message if debug mode is enabled.
      #
      # @param message [String] The message to log
      def log_debug(message)
        puts "[ExecutionStrategy] #{message}" if debug
      end
    end

    # Strategy for executing jobs sequentially, one after another.
    # Jobs are executed in the order they appear in the job group.
    class SequentialExecutionStrategy < ExecutionStrategy
      # Execute a group of jobs sequentially.
      #
      # @param job_group [Array<Job>] Jobs to execute
      # @return [Boolean] true if execution should continue
      def execute(job_group)
        log_debug "Executing #{job_group.size} jobs sequentially: #{job_group.map(&:name).join(', ')}"

        job_group.each do |job|
          execute_single_job(job)
        end

        true
      end

      private

      # Execute a single job.
      #
      # @param job [Job] The job to execute
      def execute_single_job(job)
        return unless should_execute_job?(job)

        job_trace = trace&.start_job(job_name: job.name, worker_class: job.worker_class&.name)
        job_trace&.set_input(job_input(job))

        result = execute_job_with_retry(job, job_trace)

        job_trace&.complete!(output: result)
        context.store_job_output(job.name, result)

        executor.instance_variable_get(:@completed_jobs).add(job.name)
        job.state(:completed)

        hooks.trigger(:job_complete, job, result, 0)
      rescue StandardError => e
        handle_job_error(job, e)
      end

      # Get the input for a job.
      #
      # @param job [Job] The job
      # @return [Object] The job input
      def job_input(job)
        executor.send(:prepare_job_input, job)
      end

      # Execute a job with retry logic.
      #
      # @param job [Job] The job to execute
      # @param job_trace [Object] The job trace
      # @return [Object] The execution result
      def execute_job_with_retry(job, job_trace)
        return executor.send(:execute_job_with_retry, job, job_trace) if job.retry_config

        executor.send(:execute_job_once, job, job_trace)
      end

      # Handle a job execution error.
      #
      # @param job [Job] The job that failed
      # @param error [Exception] The error
      # @raise [WorkflowError] if the error should propagate
      def handle_job_error(job, error)
        executor.instance_variable_get(:@failed_jobs).add(job.name)
        job.state(:failed)

        if job.fallback_job
          executor.send(:execute_fallback_job, job, error, nil, nil)
        else
          executor.send(:add_to_dead_letter_queue, job, error, nil)
          raise
        end
      end
    end

    # Strategy for executing jobs in parallel.
    # Jobs are executed concurrently using Supervisor.
    class ParallelExecutionStrategy < ExecutionStrategy
      # Execute a group of jobs in parallel.
      #
      # @param job_group [Array<Job>] Jobs to execute
      # @return [Boolean] true if execution should continue
      def execute(job_group)
        log_debug "Executing #{job_group.size} jobs in parallel: #{job_group.map(&:name).join(', ')}"

        executor.send(:execute_jobs_parallel, job_group)

        # Check if any jobs failed
        failed_jobs = job_group.select { |job| executor.instance_variable_get(:@failed_jobs).include?(job.name) }
        if failed_jobs.any?
          handle_parallel_errors(failed_jobs)
        end

        true
      end

      private

      # Handle errors from parallel execution.
      #
      # @param failed_jobs [Array<Job>] Jobs that failed
      # @raise [WorkflowError] If any failed jobs don't have fallbacks
      def handle_parallel_errors(failed_jobs)
        jobs_without_fallback = failed_jobs.reject(&:fallback_job)
        return if jobs_without_fallback.empty?

        error_messages = jobs_without_fallback.map(&:name).join(", ")
        raise WorkflowError, "Parallel jobs failed without fallbacks: #{error_messages}"
      end
    end

    # Strategy for executing jobs as a pipeline.
    # Jobs are executed sequentially with data flowing from one to the next.
    class PipelineExecutionStrategy < SequentialExecutionStrategy
      # Execute a group of jobs as a pipeline.
      #
      # @param job_group [Array<Job>] Jobs to execute (must be exactly 1 for pipeline)
      # @return [Boolean] true if execution should continue
      def execute(job_group)
        if job_group.size > 1
          raise WorkflowError, "Pipeline strategy expects exactly 1 job per group, got #{job_group.size}"
        end

        log_debug "Executing pipeline job: #{job_group.first.name}"

        super
      end
    end
  end
end
