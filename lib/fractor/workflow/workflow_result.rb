# frozen_string_literal: true

module Fractor
  class Workflow
    # Represents the result of a workflow execution.
    # Contains information about completed jobs, failed jobs, execution time, and output.
    class WorkflowResult
      attr_reader :workflow_name, :output, :completed_jobs, :failed_jobs,
                  :execution_time, :success, :trace, :correlation_id

      # Initialize a new workflow result.
      #
      # @param workflow_name [String] The name of the workflow
      # @param output [Object] The workflow output
      # @param completed_jobs [Array<String>] List of completed job names
      # @param failed_jobs [Array<String>] List of failed job names
      # @param execution_time [Float] Execution time in seconds
      # @param success [Boolean] Whether the workflow succeeded
      # @param trace [ExecutionTrace, nil] Optional execution trace
      # @param correlation_id [String, nil] Optional correlation ID
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

      # Check if the workflow succeeded.
      #
      # @return [Boolean] true if successful
      def success?
        @success
      end

      # Check if the workflow failed.
      #
      # @return [Boolean] true if failed
      def failed?
        !@success
      end

      # Get execution time in milliseconds.
      #
      # @return [Float] Execution time in milliseconds
      def execution_time_ms
        (@execution_time * 1000).round(2)
      end
    end
  end
end
