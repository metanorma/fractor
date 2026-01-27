# frozen_string_literal: true

require "set"
require_relative "retry_config"
require_relative "circuit_breaker_registry"
require_relative "pre_execution_context"
require_relative "execution_hooks"
require_relative "workflow_result"
require_relative "execution/dependency_resolver"
require_relative "execution/workflow_execution_logger"
require_relative "execution/job_executor"
require_relative "execution/fallback_job_handler"
require_relative "execution/result_builder"

module Fractor
  class Workflow
    # Orchestrates workflow execution by managing job execution order and data flow.
    # Refactored to use focused helper classes for each responsibility.
    class WorkflowExecutor
      attr_reader :workflow, :context, :completed_jobs, :failed_jobs,
                  :trace, :hooks, :pre_execution_context, :job_executor

      # Initialize the workflow executor.
      #
      # @param workflow [Workflow] The workflow instance to execute
      # @param input [Object] The input data for the workflow
      # @param correlation_id [String, nil] Optional correlation ID for tracking
      # @param logger [Logger, nil] Optional logger instance
      # @param trace [Boolean] Whether to enable execution tracing
      # @param dead_letter_queue [DeadLetterQueue, nil] Optional dead letter queue
      def initialize(workflow, input, correlation_id: nil, logger: nil,
                     trace: false, dead_letter_queue: nil)
        @workflow = workflow
        @correlation_id = correlation_id
        @context = WorkflowContext.new(
          input,
          correlation_id: correlation_id,
          logger: logger,
        )
        @completed_jobs = Set.new
        @failed_jobs = Set.new
        @hooks = ExecutionHooks.new
        @trace = trace ? create_trace : nil
        @circuit_breakers = CircuitBreakerRegistry.new
        @dead_letter_queue = dead_letter_queue
        @pre_execution_context = PreExecutionContext.new(workflow, input)

        # Initialize helper classes
        @logger = WorkflowExecutionLogger.new(logger)
        @job_executor = JobExecutor.new(@context, @logger,
                                        workflow: workflow,
                                        completed_jobs: @completed_jobs,
                                        failed_jobs: @failed_jobs,
                                        dead_letter_queue: @dead_letter_queue,
                                        circuit_breakers: @circuit_breakers)
        @fallback_handler = FallbackJobHandler.new(@workflow, @context, @hooks,
                                                   @logger)
      end

      # Execute the workflow and return the result.
      #
      # @return [WorkflowResult] The execution result
      def execute
        # Run pre-execution validation
        @pre_execution_context.validate!

        @logger.workflow_start(@workflow.class.workflow_name,
                               @context.correlation_id)
        @hooks.trigger(:workflow_start, @workflow)
        @trace&.start_job(
          job_name: "workflow",
          worker_class: @workflow.class.name,
        )

        resolver = DependencyResolver.new(@workflow.class.jobs)
        execution_order = resolver.execution_order
        start_time = Time.now

        execution_order.each do |job_group|
          execute_job_group(job_group)
          break if workflow_terminated?
        end

        end_time = Time.now
        @trace&.complete!

        @logger.workflow_complete(@workflow.class.workflow_name,
                                  end_time - start_time,
                                  jobs_completed: @completed_jobs.size,
                                  jobs_failed: @failed_jobs.size)

        result_builder = ResultBuilder.new(@workflow, @context, @completed_jobs,
                                           @failed_jobs, trace: @trace)
        result = result_builder.build(start_time, end_time)
        @hooks.trigger(:workflow_complete, result)
        result
      end

      # Register a hook for workflow/job lifecycle events.
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

      # Execute a group of jobs (can be run in parallel).
      #
      # @param job_names [Array<String>] Names of jobs to execute
      def execute_job_group(job_names)
        puts "Executing job group: #{job_names.inspect}" if ENV["FRACTOR_DEBUG"]
        jobs = job_names.map { |name| @workflow.class.jobs[name] }

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
          executable_jobs.each { |job| execute_job(job) }
        end
      end

      # Execute a single job with all its lifecycle management.
      #
      # @param job [Job] The job to execute
      def execute_job(job)
        puts "Executing job: #{job.name}" if ENV["FRACTOR_DEBUG"]
        job.state(:running)

        # Start job trace
        job_trace = @trace&.start_job(
          job_name: job.name,
          worker_class: job.worker_class.name,
        )

        # Log and trigger hook
        @logger.job_start(job.name, job.worker_class.name)
        @hooks.trigger(:job_start, job, @context)

        start_time = Time.now

        begin
          # Execute with retry logic if configured
          output = if job.retry_enabled?
                     @job_executor.execute_with_retry(job, job_trace)
                   else
                     @job_executor.execute_once(job, job_trace)
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
          @logger.job_complete(job.name, duration)
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
          @logger.job_error(job.name, e, has_fallback: !!job.fallback_job)
          @hooks.trigger(:job_error, job, e, @context)

          puts "Job '#{job.name}' failed: #{e.message}" if ENV["FRACTOR_DEBUG"]

          # Try fallback job if configured
          if job.fallback_job
            @fallback_handler.execute_fallback(job, e, job_trace,
                                               @job_executor, start_time)
            # Fallback succeeded - add original job to completed
            @completed_jobs.add(job.name)
          else
            raise WorkflowExecutionError,
                  "Job '#{job.name}' failed: #{e.message}\n#{e.backtrace.join("\n")}"
          end
        end
      end

      # Check if the workflow should terminate early.
      #
      # @return [Boolean] true if workflow should terminate
      def workflow_terminated?
        # Check if any terminating job has completed
        @workflow.class.jobs.each do |name, job|
          return true if job.terminates && @completed_jobs.include?(name)
        end
        false
      end

      # Create an execution trace.
      #
      # @return [ExecutionTrace] The execution trace
      def create_trace
        require "securerandom"
        execution_id = "exec-#{SecureRandom.hex(8)}"
        ExecutionTrace.new(
          workflow_name: @workflow.class.workflow_name,
          execution_id: execution_id,
          correlation_id: @context.correlation_id,
        )
      end

      # Backward compatibility: Access dead letter queue.
      #
      # @return [DeadLetterQueue, nil] The DLQ or nil
      def dead_letter_queue
        @dead_letter_queue
      end

      # Backward compatibility: Execute a job once without retry.
      # This is used by ExecutionStrategy classes.
      #
      # @param job [Job] The job to execute
      # @param job_trace [ExecutionTrace::JobTrace, nil] Optional job trace
      # @return [Object] The job output
      def execute_job_once(job, job_trace = nil)
        @job_executor.execute_once(job, job_trace)
      end

      # Backward compatibility: Add failed job to dead letter queue.
      # This is used by ExecutionStrategy classes.
      #
      # @param job [Job] The job that failed
      # @param error [Exception] The error that occurred
      # @param retry_state [Object, nil] Optional retry state
      def add_to_dead_letter_queue(job, error, retry_state = nil)
        @job_executor.send(:add_to_dead_letter_queue, job, error, retry_state)
      end

      # Backward compatibility: Execute jobs in parallel.
      # This is used by ExecutionStrategy classes.
      # Note: Current implementation executes jobs sequentially to avoid Ractor issues.
      #
      # @param jobs [Array<Job>] Jobs to execute
      def execute_jobs_parallel(jobs)
        puts "Executing #{jobs.size} jobs in parallel: #{jobs.map(&:name).join(', ')}" if ENV["FRACTOR_DEBUG"]

        # Execute sequentially for now (parallel execution with Ractors has issues)
        jobs.each { |job| execute_job(job) }
      end
    end
  end
end
