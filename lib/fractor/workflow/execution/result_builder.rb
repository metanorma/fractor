# frozen_string_literal: true

require_relative "../workflow_result"

module Fractor
  class Workflow
    # Builds the final workflow result from completed jobs and context.
    # Responsible for finding the workflow output and creating the result object.
    class ResultBuilder
      # Initialize the result builder.
      #
      # @param workflow [Workflow] The workflow instance
      # @param context [WorkflowContext] The execution context
      # @param completed_jobs [Set<String>] Set of completed job names
      # @param failed_jobs [Set<String>] Set of failed job names
      # @param trace [ExecutionTrace, nil] Optional execution trace
      def initialize(workflow, context, completed_jobs, failed_jobs, trace: nil)
        @workflow = workflow
        @context = context
        @completed_jobs = completed_jobs
        @failed_jobs = failed_jobs
        @trace = trace
      end

      # Build the workflow result.
      #
      # @param start_time [Time] Workflow start time
      # @param end_time [Time] Workflow end time
      # @return [WorkflowResult] The workflow execution result
      def build(start_time, end_time)
        output = find_workflow_output

        WorkflowResult.new(
          workflow_name: @workflow.class.workflow_name,
          output: output,
          completed_jobs: @completed_jobs.to_a,
          failed_jobs: @failed_jobs.to_a,
          execution_time: end_time - start_time,
          success: @failed_jobs.empty?,
          trace: @trace,
          correlation_id: @context.correlation_id,
        )
      end

      private

      # Find the workflow output from completed jobs.
      # Looks for jobs marked with outputs_to_workflow, then falls back to end jobs.
      #
      # @return [Object, nil] The workflow output, or nil if not found
      def find_workflow_output
        # Look for jobs that map to workflow output
        @workflow.class.jobs.each do |name, job|
          if job.outputs_to_workflow? && @completed_jobs.include?(name)
            output = @context.job_output(name)
            puts "Found workflow output from job '#{name}': #{output.class}" if ENV["FRACTOR_DEBUG"]
            return output
          end
        end

        # Fallback: return output from the first end job that completed
        @workflow.class.end_job_names.each do |end_job_spec|
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
