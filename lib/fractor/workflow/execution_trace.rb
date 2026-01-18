# frozen_string_literal: true

require "time"

module Fractor
  class Workflow
    # Tracks execution details for workflow runs.
    # Provides detailed trace of job execution, timings, and results.
    class ExecutionTrace
      attr_reader :workflow_name, :execution_id, :correlation_id,
                  :started_at, :completed_at, :job_traces

      def initialize(workflow_name:, execution_id:, correlation_id:)
        @workflow_name = workflow_name
        @execution_id = execution_id
        @correlation_id = correlation_id
        @started_at = Time.now.utc
        @completed_at = nil
        @job_traces = []
      end

      # Record the start of a job execution
      def start_job(job_name:, worker_class:)
        job_trace = JobTrace.new(
          job_name: job_name,
          worker_class: worker_class,
        )
        @job_traces << job_trace
        job_trace
      end

      # Mark the workflow as completed
      def complete!
        @completed_at = Time.now.utc
      end

      # Total duration in milliseconds
      def total_duration_ms
        return nil unless @completed_at

        ((@completed_at - @started_at) * 1000).round(2)
      end

      # Convert trace to hash for serialization
      def to_h
        {
          workflow: @workflow_name,
          execution_id: @execution_id,
          correlation_id: @correlation_id,
          started_at: @started_at.strftime("%Y-%m-%dT%H:%M:%S.%3NZ"),
          completed_at: @completed_at&.strftime("%Y-%m-%dT%H:%M:%S.%3NZ"),
          total_duration_ms: total_duration_ms,
          jobs: @job_traces.map(&:to_h),
        }
      end

      # Convert trace to JSON
      def to_json(*_args)
        to_h.to_json
      end

      # Trace data for a single job execution
      class JobTrace
        attr_reader :job_name, :worker_class, :started_at,
                    :completed_at, :status, :error

        def initialize(job_name:, worker_class:)
          @job_name = job_name
          @worker_class = worker_class
          @started_at = Time.now.utc
          @completed_at = nil
          @status = :running
          @error = nil
          @input_hash = nil
          @output_hash = nil
        end

        # Mark job as successfully completed
        def complete!(output: nil)
          @completed_at = Time.now.utc
          @status = :success
          @output_hash = hash_value(output) if output
        end

        # Mark job as failed
        def fail!(error:)
          @completed_at = Time.now.utc
          @status = :failed
          @error = {
            class: error.class.name,
            message: error.message,
            backtrace: error.backtrace&.first(5),
          }
        end

        # Set input hash for tracking
        def set_input(input)
          @input_hash = hash_value(input)
        end

        # Duration in milliseconds
        def duration_ms
          return nil unless @completed_at

          ((@completed_at - @started_at) * 1000).round(2)
        end

        # Convert to hash for serialization
        def to_h
          {
            name: @job_name,
            worker: @worker_class,
            started_at: @started_at.strftime("%Y-%m-%dT%H:%M:%S.%3NZ"),
            completed_at: @completed_at&.strftime("%Y-%m-%dT%H:%M:%S.%3NZ"),
            duration_ms: duration_ms,
            status: @status.to_s,
            input_hash: @input_hash,
            output_hash: @output_hash,
            error: @error,
          }.compact
        end

        private

        def hash_value(value)
          return nil unless value

          # Create a simple hash for tracking (not cryptographic)
          value.to_s.hash.abs.to_s(16)[0..7]
        end
      end
    end
  end
end
