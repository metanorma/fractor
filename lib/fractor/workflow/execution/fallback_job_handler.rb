# frozen_string_literal: true

module Fractor
  class Workflow
    # Handles fallback job execution when a primary job fails.
    # Manages the lifecycle of executing a fallback job and integrating
    # its result back into the workflow context.
    class FallbackJobHandler
      # Initialize the fallback handler.
      #
      # @param workflow [Workflow] The workflow instance
      # @param context [WorkflowContext] The execution context
      # @param hooks [ExecutionHooks] Execution hooks for event notification
      # @param logger [WorkflowLogger] The workflow logger
      def initialize(workflow, context, hooks, logger)
        @workflow = workflow
        @context = context
        @hooks = hooks
        @logger = logger
      end

      # Execute a fallback job for a failed job.
      #
      # @param original_job [Job] The job that failed
      # @param original_error [Exception] The error that occurred
      # @param job_trace [ExecutionTrace::JobTrace, nil] Optional job trace
      # @param job_executor [JobExecutor] The job executor to use
      # @param start_time [Time] The original job start time (for duration calculation)
      # @return [Object] The output from the fallback job
      def execute_fallback(original_job, original_error, job_trace,
job_executor, start_time)
        fallback_job_name = original_job.fallback_job
        fallback_job = @workflow.class.jobs[fallback_job_name]

        unless fallback_job
          raise WorkflowExecutionError,
                "Fallback job '#{fallback_job_name}' not found for job '#{original_job.name}'"
        end

        @logger.fallback_execution(original_job.name, fallback_job.name,
                                   original_error)

        begin
          # Execute fallback job using job_executor
          output = job_executor.execute_once(fallback_job, job_trace)

          # Store output under original job name as well
          @context.store_job_output(original_job.name, output)
          original_job.state(:completed)

          duration = Time.now - start_time

          # Update trace
          job_trace&.complete!(output: output)

          @logger.job_complete(original_job.name, duration)
          @hooks.trigger(:job_complete, original_job, output, duration)

          output
        rescue StandardError => e
          @logger.fallback_failed(original_job.name, fallback_job.name, e)
          raise WorkflowExecutionError,
                "Job '#{original_job.name}' and fallback '#{fallback_job_name}' both failed"
        end
      end
    end
  end
end
