# frozen_string_literal: true

require_relative "../../supervisor"
require_relative "../../work"
require_relative "../retry_orchestrator"

module Fractor
  class Workflow
    # Executes a single workflow job, handling all aspects of job execution
    # including input building, work creation, and supervisor orchestration.
    class JobExecutor
      attr_reader :context, :logger, :dead_letter_queue

      # Initialize the job executor.
      #
      # @param context [WorkflowContext] The workflow execution context
      # @param logger [WorkflowLogger] The workflow logger
      # @param workflow [Workflow] The workflow instance
      # @param completed_jobs [Set<String>] Set of completed job names
      # @param failed_jobs [Set<String>] Set of failed job names
      # @param dead_letter_queue [DeadLetterQueue, nil] Optional DLQ for failed jobs
      # @param circuit_breakers [CircuitBreakerRegistry] Circuit breaker registry
      def initialize(context, logger, workflow: nil, completed_jobs: nil, failed_jobs: nil,
                     dead_letter_queue: nil, circuit_breakers: nil)
        @context = context
        @logger = logger
        @workflow = workflow
        @completed_jobs = completed_jobs || Set.new
        @failed_jobs = failed_jobs || Set.new
        @dead_letter_queue = dead_letter_queue
        @circuit_breakers = circuit_breakers || CircuitBreakerRegistry.new
      end

      # Execute a job once (no retry logic).
      #
      # @param job [Job] The job to execute
      # @param job_trace [ExecutionTrace::JobTrace, nil] Optional job trace
      # @return [Object] The job output
      def execute_once(job, job_trace = nil)
        # Build input for this job
        job_input = @context.build_job_input(job)
        job_trace&.set_input(job_input)

        # Create work item - if job_input is already a Work object, use it directly
        # to avoid double-wrapping (e.g., when using custom Work subclasses)
        work = if job_input.is_a?(Work)
                 job_input
               else
                 Work.new(job_input)
               end

        # Execute with circuit breaker if configured
        if job.circuit_breaker_enabled?
          execute_with_circuit_breaker(job, work, job_trace)
        else
          execute_with_supervisor(job, work)
        end
      end

      # Execute a job with retry logic.
      #
      # @param job [Job] The job to execute
      # @param job_trace [ExecutionTrace::JobTrace, nil] Optional job trace
      # @return [Object] The job output
      def execute_with_retry(job, job_trace = nil)
        retry_config = job.retry_config

        # Create retry orchestrator with the job's retry configuration
        orchestrator = RetryOrchestrator.new(retry_config,
                                             debug: ENV["FRACTOR_DEBUG"] == "1")

        # Execute with retry logic
        orchestrator.execute_with_retry(job) do |j|
          execute_once(j, job_trace)
        end
      rescue StandardError => e
        # Get retry state for DLQ entry
        retry_state = orchestrator.state
        add_to_dead_letter_queue(job, e, retry_state)
        raise e
      end

      # Execute a job using a supervisor.
      #
      # @param job [Job] The job to execute
      # @param work [Work] The work item to process
      # @return [Object] The job output
      def execute_with_supervisor(job, work)
        supervisor = Supervisor.new(
          worker_pools: [
            {
              worker_class: job.worker_class,
              num_workers: job.num_workers || 1,
            },
          ],
        )

        supervisor.add_work_item(work)
        supervisor.run

        # Check for errors first (before checking results)
        unless supervisor.results.errors.empty?
          error = supervisor.results.errors.first
          raise WorkflowExecutionError,
                "Job '#{job.name}' encountered error: #{error.error}"
        end

        # Get the result
        results = supervisor.results.results
        if results.empty?
          raise WorkflowExecutionError, "Job '#{job.name}' produced no results"
        end

        results.first.result
      end

      # Execute a job with circuit breaker protection.
      #
      # @param job [Job] The job to execute
      # @param work [Work] The work item to process
      # @param job_trace [ExecutionTrace::JobTrace, nil] Optional job trace
      # @return [Object] The job output
      def execute_with_circuit_breaker(job, work, _job_trace = nil)
        breaker_key = job.circuit_breaker_key

        # Get or create circuit breaker orchestrator for this job
        orchestrator = @circuit_breakers.get_or_create_orchestrator(
          breaker_key,
          **job.circuit_breaker_config.slice(:threshold, :timeout,
                                             :half_open_calls),
          job_name: job.name,
          debug: ENV["FRACTOR_DEBUG"] == "1",
        )

        # Log circuit state before execution
        log_circuit_breaker_state(job, orchestrator)

        begin
          orchestrator.execute_with_breaker(job) do
            execute_with_supervisor(job, work)
          end
        rescue Workflow::CircuitOpenError => e
          log_circuit_breaker_open(job, orchestrator)
          raise WorkflowExecutionError,
                "Circuit breaker open for job '#{job.name}': #{e.message}"
        end
      end

      private

      # Add failed job to dead letter queue.
      #
      # @param job [Job] The job that failed
      # @param error [Exception] The error that occurred
      # @param retry_state [Object, nil] Optional retry state
      def add_to_dead_letter_queue(job, error, retry_state = nil)
        return unless @dead_letter_queue

        # Build job input for DLQ entry
        job_input = @context.build_job_input(job)
        work = Work.new(job_input)

        # Build metadata about the failure
        metadata = build_failure_metadata(job, error, retry_state)

        # Build context from workflow
        context = {
          workflow_input: @context.workflow_input,
          completed_jobs: @completed_jobs.to_a,
          failed_jobs: @failed_jobs.to_a,
        }

        @dead_letter_queue.add(work, error, context: context,
                                            metadata: metadata)

        @logger.added_to_dead_letter_queue(job.name, error,
                                           @dead_letter_queue.size)
      end

      # Build failure metadata for dead letter queue.
      #
      # @param job [Job] The job that failed
      # @param error [Exception] The error that occurred
      # @param retry_state [Object, nil] Optional retry state
      # @return [Hash] Failure metadata
      def build_failure_metadata(job, _error, retry_state)
        metadata = {
          job_name: job.name,
          worker_class: job.worker_class.name,
          correlation_id: @context.correlation_id,
          workflow_name: @workflow.class.workflow_name,
        }

        # Add retry information if available
        if retry_state
          # Handle both RetryState object and Hash from orchestrator
          if retry_state.is_a?(Hash)
            # From RetryOrchestrator.state
            metadata[:retry_attempts] = retry_state[:attempts] - 1
            metadata[:max_attempts] = retry_state[:max_attempts]
            metadata[:last_error] = retry_state[:last_error]
            metadata[:total_retry_time] = retry_state[:total_time]
            metadata[:all_errors] = retry_state[:all_errors]
          else
            # From RetryState object
            metadata[:retry_attempts] = retry_state.attempt - 1
            metadata[:total_retry_time] = retry_state.total_time
            metadata[:all_errors] = retry_state.summary[:errors]
          end
        end

        metadata
      end

      # Log circuit breaker state.
      #
      # @param job [Job] The job
      # @param orchestrator [CircuitBreakerOrchestrator] The circuit breaker orchestrator
      def log_circuit_breaker_state(job, orchestrator)
        @logger.circuit_breaker_state(
          job.name,
          orchestrator.state,
          failure_count: orchestrator.failure_count,
          threshold: orchestrator.breaker.threshold,
        )
      end

      # Log circuit breaker open.
      #
      # @param job [Job] The job
      # @param orchestrator [CircuitBreakerOrchestrator] The circuit breaker orchestrator
      def log_circuit_breaker_open(job, orchestrator)
        @logger.circuit_breaker_open(
          job.name,
          orchestrator.failure_count,
          orchestrator.breaker.threshold,
          last_failure: orchestrator.breaker.last_failure_time,
        )
      end
    end
  end
end
