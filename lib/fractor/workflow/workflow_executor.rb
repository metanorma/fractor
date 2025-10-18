# frozen_string_literal: true

require "set"

module Fractor
  class Workflow
    # Orchestrates workflow execution by managing job execution order and data flow.
    class WorkflowExecutor
      attr_reader :workflow, :context, :completed_jobs, :failed_jobs,
                  :trace, :hooks

      def initialize(workflow, input, correlation_id: nil, logger: nil,
trace: false)
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
      end

      # Execute the workflow and return the result.
      #
      # @return [WorkflowResult] The execution result
      def execute
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
          # Build input for this job
          job_input = @context.build_job_input(job)
          job_trace&.set_input(job_input)

          # Create work item
          work = Work.new(job_input)

          # Execute using existing Fractor infrastructure
          output = execute_job_with_supervisor(job, work)

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

          # Log and trigger hook
          log_job_error(job, e)
          @hooks.trigger(:job_error, job, e, @context)

          puts "Job '#{job.name}' failed: #{e.message}" if ENV["FRACTOR_DEBUG"]
          raise WorkflowExecutionError,
                "Job '#{job.name}' failed: #{e.message}\n#{e.backtrace.join("\n")}"
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

        # Get the result
        results = supervisor.results.results
        if results.empty?
          raise WorkflowExecutionError, "Job '#{job.name}' produced no results"
        end

        # Check for errors
        unless supervisor.results.errors.empty?
          error = supervisor.results.errors.first
          raise WorkflowExecutionError,
                "Job '#{job.name}' encountered error: #{error.error}"
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

    # Represents the result of a workflow execution.
    class WorkflowResult
      attr_reader :workflow_name, :output, :completed_jobs, :failed_jobs,
                  :execution_time, :success, :trace, :correlation_id

      def initialize(workflow_name:, output:, completed_jobs:, failed_jobs:,
                     execution_time:, success:, trace: nil, correlation_id: nil)
        @workflow_name = workflow_name
        @output = output
        @completed_jobs = completed_jobs
        @failed_jobs = failed_jobs
        @execution_time = execution_time
        @success = success
        @trace = trace
        @correlation_id = correlation_id
      end

      def success?
        @success
      end

      def failed?
        !@success
      end

      # Get execution time in milliseconds
      def execution_time_ms
        (@execution_time * 1000).round(2)
      end
    end

    # Manages lifecycle hooks for workflow execution
    class ExecutionHooks
      def initialize
        @hooks = Hash.new { |h, k| h[k] = [] }
      end

      def register(event, &block)
        @hooks[event] << block
      end

      def trigger(event, *args)
        @hooks[event].each do |hook|
          hook.call(*args)
        end
      end
    end
  end
end
