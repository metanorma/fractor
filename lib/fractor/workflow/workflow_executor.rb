# frozen_string_literal: true

require "set"
require_relative "retry_config"
require_relative "circuit_breaker"
require_relative "circuit_breaker_registry"
require_relative "circuit_breaker_orchestrator"
require_relative "retry_orchestrator"
require_relative "pre_execution_context"
require_relative "execution_hooks"
require_relative "workflow_result"

module Fractor
  class Workflow
    # Orchestrates workflow execution by managing job execution order and data flow.
    class WorkflowExecutor
      attr_reader :workflow, :context, :completed_jobs, :failed_jobs,
                  :trace, :hooks, :pre_execution_context

      def initialize(workflow, input, correlation_id: nil, logger: nil,
trace: false, dead_letter_queue: nil)
        @workflow = workflow
        @correlation_id = correlation_id
        @logger = logger
        @context = WorkflowContext.new(
          input,
          correlation_id: correlation_id,
          logger: logger,
        )
        @completed_jobs = Set.new
        @failed_jobs = Set.new
        @hooks = ExecutionHooks.new
        @trace = trace ? create_trace : nil
        @circuit_breakers = Workflow::CircuitBreakerRegistry.new
        @dead_letter_queue = dead_letter_queue
        @pre_execution_context = PreExecutionContext.new(workflow, input)
      end

      # Execute the workflow and return the result.
      #
      # @return [WorkflowResult] The execution result
      def execute
        # Run pre-execution validation
        @pre_execution_context.validate!

        log_workflow_start
        @hooks.trigger(:workflow_start, workflow)
        @trace&.start_job(
          job_name: "workflow",
          worker_class: workflow.class.name,
        )

        execution_order = compute_execution_order
        start_time = Time.now

        execution_order.each do |job_group|
          execute_job_group(job_group)
          break if workflow_terminated?
        end

        end_time = Time.now
        @trace&.complete!

        log_workflow_complete(end_time - start_time)
        result = build_result(start_time, end_time)
        @hooks.trigger(:workflow_complete, result)
        result
      end

      # Register a hook for workflow/job lifecycle events
      #
      # @param event [Symbol] The event to hook into
      # @param block [Proc] The callback to execute
      def on(event, &)
        @hooks.register(event, &)
      end

      # Register a custom pre-execution validation hook.
      # The hook receives the PreExecutionContext and can add errors/warnings.
      #
      # @param name [String, Symbol] Optional name for the validation
      # @yield [context] Block that receives the pre-execution context
      #
      # @example Add custom validation
      #   executor.validate_before_execution(:check_api_key) do |ctx|
      #     unless ctx.input.api_key
      #       ctx.add_error("API key is required")
      #     end
      #   end
      def validate_before_execution(name = nil, &)
        @pre_execution_context.add_validation_hook(name, &)
      end

      private

      def compute_execution_order
        # Topological sort to determine execution order
        # Returns array of arrays (each inner array is a group of parallelizable jobs)
        jobs = workflow.class.jobs
        order = []
        remaining = jobs.keys.to_set
        processed = Set.new

        until remaining.empty?
          # Find jobs whose dependencies are all satisfied
          ready = remaining.select do |job_name|
            job = jobs[job_name]
            job.dependencies.all? { |dep| processed.include?(dep) }
          end

          if ready.empty?
            # This should not happen if validation was done correctly
            raise WorkflowExecutionError,
                  "Cannot find next jobs to execute. Remaining: #{remaining.to_a.join(', ')}"
          end

          order << ready
          ready.each do |job_name|
            processed.add(job_name)
            remaining.delete(job_name)
          end
        end

        puts "Execution order: #{order.inspect}" if ENV["FRACTOR_DEBUG"]
        order
      end

      def execute_job_group(job_names)
        puts "Executing job group: #{job_names.inspect}" if ENV["FRACTOR_DEBUG"]
        jobs = job_names.map { |name| workflow.class.jobs[name] }

        # Filter jobs based on conditions
        executable_jobs = jobs.select { |job| job.should_execute?(@context) }

        # Mark skipped jobs
        (jobs - executable_jobs).each do |job|
          job.state(:skipped)
          puts "Job '#{job.name}' skipped due to condition" if ENV["FRACTOR_DEBUG"]
        end

        return if executable_jobs.empty?

        if executable_jobs.size == 1
          # Single job - execute directly
          execute_job(executable_jobs.first)
        else
          # Multiple jobs - execute sequentially (not parallel to avoid Ractor issues)
          puts "Executing #{executable_jobs.size} jobs sequentially" if ENV["FRACTOR_DEBUG"]
          executable_jobs.each do |job|
            execute_job(job)
          end
        end
      end

      def execute_job(job)
        puts "Executing job: #{job.name}" if ENV["FRACTOR_DEBUG"]
        job.state(:running)

        # Start job trace
        job_trace = @trace&.start_job(
          job_name: job.name,
          worker_class: job.worker_class.name,
        )

        # Log and trigger hook
        log_job_start(job)
        @hooks.trigger(:job_start, job, @context)

        start_time = Time.now

        begin
          # Execute with retry logic if configured
          output = if job.retry_enabled?
                     execute_job_with_retry(job, job_trace)
                   else
                     execute_job_once(job, job_trace)
                   end

          # Calculate duration
          duration = Time.now - start_time

          # Store output in context
          @context.store_job_output(job.name, output)
          @completed_jobs.add(job.name)
          job.state(:completed)

          # Update trace
          job_trace&.complete!(output: output)

          # Log and trigger hook
          log_job_complete(job, duration)
          @hooks.trigger(:job_complete, job, output, duration)

          puts "Job '#{job.name}' completed successfully" if ENV["FRACTOR_DEBUG"]
        rescue StandardError => e
          Time.now - start_time
          @failed_jobs.add(job.name)
          job.state(:failed)

          # Update trace
          job_trace&.fail!(error: e)

          # Execute error handlers
          job.handle_error(e, @context)

          # Log and trigger hook
          log_job_error(job, e)
          @hooks.trigger(:job_error, job, e, @context)

          puts "Job '#{job.name}' failed: #{e.message}" if ENV["FRACTOR_DEBUG"]

          # Try fallback job if configured
          if job.fallback_job
            execute_fallback_job(job, e, start_time, job_trace)
          else
            raise WorkflowExecutionError,
                  "Job '#{job.name}' failed: #{e.message}\n#{e.backtrace.join("\n")}"
          end
        end
      end

      def execute_job_once(job, job_trace)
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
          execute_with_circuit_breaker(job, work)
        else
          execute_job_with_supervisor(job, work)
        end
      end

      def execute_job_with_retry(job, job_trace)
        retry_config = job.retry_config

        # Create retry orchestrator with the job's retry configuration
        orchestrator = RetryOrchestrator.new(retry_config,
                                             debug: ENV["FRACTOR_DEBUG"] == "1")

        # Execute with retry logic
        orchestrator.execute_with_retry(job) do |j|
          execute_job_once(j, job_trace)
        end
      rescue StandardError => e
        # Get retry state for DLQ entry
        retry_state = orchestrator.state
        add_to_dead_letter_queue(job, e, retry_state)
        raise e
      end

      def execute_fallback_job(job, error, start_time, job_trace)
        fallback_job_name = job.fallback_job
        fallback_job = workflow.class.jobs[fallback_job_name]

        unless fallback_job
          raise WorkflowExecutionError,
                "Fallback job '#{fallback_job_name}' not found for job '#{job.name}'"
        end

        log_fallback_execution(job, fallback_job, error)

        begin
          # Execute fallback job
          execute_job(fallback_job)

          # Use fallback job's output
          output = @context.job_output(fallback_job_name)
          duration = Time.now - start_time

          # Store output under original job name as well
          @context.store_job_output(job.name, output)
          @completed_jobs.add(job.name)
          job.state(:completed)

          # Update trace
          job_trace&.complete!(output: output)

          log_job_complete(job, duration)
          @hooks.trigger(:job_complete, job, output, duration)
        rescue StandardError => e
          log_fallback_failed(job, fallback_job, e)
          raise WorkflowExecutionError,
                "Job '#{job.name}' and fallback '#{fallback_job_name}' both failed"
        end
      end

      def execute_jobs_parallel(jobs)
        puts "Executing #{jobs.size} jobs in parallel: #{jobs.map(&:name).join(', ')}" if ENV["FRACTOR_DEBUG"]

        # Create supervisors for each job
        supervisors = jobs.map do |job|
          job.state(:running)
          job_input = @context.build_job_input(job)
          work = Work.new(job_input)

          supervisor = Supervisor.new(
            worker_pools: [
              {
                worker_class: job.worker_class,
                num_workers: job.num_workers || 1,
              },
            ],
          )
          supervisor.add_work_item(work)

          { job: job, supervisor: supervisor }
        end

        # Run all supervisors in parallel using threads
        threads = supervisors.map do |spec|
          Thread.new do
            spec[:supervisor].run
            { job: spec[:job], success: true, supervisor: spec[:supervisor] }
          rescue StandardError => e
            { job: spec[:job], success: false, error: e }
          end
        end

        # Wait for all to complete and process results
        threads.each do |thread|
          result = thread.value
          job = result[:job]

          if result[:success]
            # Extract output from supervisor results
            job_results = result[:supervisor].results.results
            if job_results.empty?
              raise WorkflowExecutionError,
                    "Job '#{job.name}' produced no results"
            end

            output = job_results.first.result
            @context.store_job_output(job.name, output)
            @completed_jobs.add(job.name)
            job.state(:completed)

            puts "Job '#{job.name}' completed successfully" if ENV["FRACTOR_DEBUG"]
          else
            @failed_jobs.add(job.name)
            job.state(:failed)
            error = result[:error]
            puts "Job '#{job.name}' failed: #{error.message}" if ENV["FRACTOR_DEBUG"]
            raise WorkflowExecutionError,
                  "Job '#{job.name}' failed: #{error.message}"
          end
        end
      end

      def execute_job_with_supervisor(job, work)
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

      def workflow_terminated?
        # Check if any terminating job has completed
        workflow.class.jobs.each do |name, job|
          return true if job.terminates && @completed_jobs.include?(name)
        end
        false
      end

      def create_trace
        require "securerandom"
        execution_id = "exec-#{SecureRandom.hex(8)}"
        ExecutionTrace.new(
          workflow_name: workflow.class.workflow_name,
          execution_id: execution_id,
          correlation_id: @context.correlation_id,
        )
      end

      def log_workflow_start
        return unless @context.logger

        @context.logger.info(
          "Workflow starting",
          workflow: workflow.class.workflow_name,
          correlation_id: @context.correlation_id,
        )
      end

      def log_workflow_complete(duration)
        return unless @context.logger

        @context.logger.info(
          "Workflow complete",
          workflow: workflow.class.workflow_name,
          duration_ms: (duration * 1000).round(2),
          jobs_completed: @completed_jobs.size,
          jobs_failed: @failed_jobs.size,
        )
      end

      def log_job_start(job)
        return unless @context.logger

        @context.logger.info(
          "Job starting",
          job: job.name,
          worker: job.worker_class.name,
        )
      end

      def log_job_complete(job, duration)
        return unless @context.logger

        @context.logger.info(
          "Job complete",
          job: job.name,
          duration_ms: (duration * 1000).round(2),
        )
      end

      def log_job_error(job, error)
        return unless @context.logger

        @context.logger.error(
          "Job failed",
          job: job.name,
          error: error.class.name,
          message: error.message,
        )
      end

      def log_retry_attempt(job, retry_state, delay)
        return unless @context.logger

        @context.logger.warn(
          "Job retry attempt",
          job: job.name,
          attempt: retry_state.attempt,
          max_attempts: job.retry_config.max_attempts,
          delay_seconds: delay,
          last_error: retry_state.last_error&.message,
        )
      end

      def log_retry_success(job, retry_state)
        return unless @context.logger

        @context.logger.info(
          "Job retry succeeded",
          job: job.name,
          successful_attempt: retry_state.attempt,
          total_attempts: retry_state.attempt,
          total_time: retry_state.total_time,
        )
      end

      def log_retry_exhausted(job, retry_state)
        return unless @context.logger

        @context.logger.error(
          "Job retry attempts exhausted",
          job: job.name,
          total_attempts: retry_state.attempt - 1,
          total_time: retry_state.total_time,
          errors: retry_state.summary[:errors],
        )
      end

      def log_fallback_execution(job, fallback_job, error)
        return unless @context.logger

        @context.logger.warn(
          "Executing fallback job",
          job: job.name,
          fallback_job: fallback_job.name,
          original_error: error.message,
        )
      end

      def log_fallback_failed(job, fallback_job, error)
        return unless @context.logger

        @context.logger.error(
          "Fallback job failed",
          job: job.name,
          fallback_job: fallback_job.name,
          error: error.message,
        )
      end

      def execute_with_circuit_breaker(job, work)
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
            execute_job_with_supervisor(job, work)
          end
        rescue Workflow::CircuitOpenError => e
          log_circuit_breaker_open(job, orchestrator)
          raise WorkflowExecutionError,
                "Circuit breaker open for job '#{job.name}': #{e.message}"
        end
      end

      def log_circuit_breaker_state(job, breaker)
        return unless @context.logger
        return if breaker.closed?

        @context.logger.warn(
          "Circuit breaker state",
          job: job.name,
          state: breaker.state,
          failure_count: breaker.failure_count,
          threshold: breaker.threshold,
        )
      end

      def log_circuit_breaker_open(job, breaker)
        return unless @context.logger

        @context.logger.error(
          "Circuit breaker open",
          job: job.name,
          failure_count: breaker.failure_count,
          threshold: breaker.threshold,
          last_failure: breaker.last_failure_time,
        )
      end

      def add_to_dead_letter_queue(job, error, retry_state = nil)
        return unless @dead_letter_queue

        # Build job input for DLQ entry
        job_input = @context.build_job_input(job)
        work = Work.new(job_input)

        # Add metadata about the failure
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

        # Add context from workflow
        context = {
          workflow_input: @context.workflow_input,
          completed_jobs: @completed_jobs.to_a,
          failed_jobs: @failed_jobs.to_a,
        }

        @dead_letter_queue.add(work, error, context: context,
                                            metadata: metadata)

        log_added_to_dlq(job, error) if @context.logger
      end

      def log_added_to_dlq(job, error)
        @context.logger.warn(
          "Work added to Dead Letter Queue",
          job: job.name,
          error: error.class.name,
          message: error.message,
          dlq_size: @dead_letter_queue.size,
        )
      end

      def build_result(start_time, end_time)
        # Find the output from the end job
        output = find_workflow_output

        WorkflowResult.new(
          workflow_name: workflow.class.workflow_name,
          output: output,
          completed_jobs: @completed_jobs.to_a,
          failed_jobs: @failed_jobs.to_a,
          execution_time: end_time - start_time,
          success: @failed_jobs.empty?,
          trace: @trace,
          correlation_id: @context.correlation_id,
        )
      end

      def find_workflow_output
        # Look for jobs that map to workflow output
        workflow.class.jobs.each do |name, job|
          if job.outputs_to_workflow? && @completed_jobs.include?(name)
            output = @context.job_output(name)
            puts "Found workflow output from job '#{name}': #{output.class}" if ENV["FRACTOR_DEBUG"]
            return output
          end
        end

        # Fallback: return output from the first end job that completed
        workflow.class.end_job_names.each do |end_job_spec|
          job_name = end_job_spec[:name]
          if @completed_jobs.include?(job_name)
            output = @context.job_output(job_name)
            puts "Using end job '#{job_name}' output: #{output.class}" if ENV["FRACTOR_DEBUG"]
            return output
          end
        end

        puts "Warning: No workflow output found!" if ENV["FRACTOR_DEBUG"]
        nil
      end
    end
  end
end
