# frozen_string_literal: true

require "spec_helper"
require_relative "../../../examples/workflow/dead_letter_queue/dead_letter_queue_workflow"

RSpec.describe "Dead Letter Queue Workflow Examples" do
  describe BasicDLQWorkflow do
    it "captures failed work in DLQ after retry exhaustion" do
      workflow = described_class.new({ action: "fail_always",
                                       message: "Test failure" })

      expect do
        workflow.execute
      end.to raise_error(Fractor::WorkflowExecutionError)

      # Check DLQ captured the failure
      dlq = workflow.dead_letter_queue
      expect(dlq.size).to eq(1)

      entry = dlq.all.first
      expect(entry.error).to be_a(Fractor::WorkflowExecutionError)
      expect(entry.error.message).to include("Permanent failure")
      expect(entry.metadata[:job_name]).to eq("unreliable_task")
    end

    it "includes retry metadata in DLQ entry" do
      workflow = described_class.new({ action: "fail_always", message: "Test" })

      expect do
        workflow.execute
      end.to raise_error(Fractor::WorkflowExecutionError)

      entry = workflow.dead_letter_queue.all.first
      expect(entry.metadata[:retry_attempts]).to be >= 2
      expect(entry.metadata[:total_retry_time]).to be > 0
      expect(entry.metadata[:all_errors]).to be_an(Array)
    end
  end

  describe DLQWithHandlersWorkflow do
    it "triggers on_add callback when entry is added" do
      callback_triggered = false
      workflow = described_class.new({ action: "fail_always", message: "Test" })

      # Override the on_add callback for testing
      dlq = workflow.dead_letter_queue
      dlq.on_add do |_entry|
        callback_triggered = true
      end

      expect do
        workflow.execute
      end.to raise_error(Fractor::WorkflowExecutionError)

      expect(callback_triggered).to be true
    end
  end

  describe DLQWithPersistenceWorkflow do
    let(:dlq_dir) { "tmp/test_dlq" }

    before do
      FileUtils.rm_rf(dlq_dir)
      FileUtils.mkdir_p(dlq_dir)
    end

    after do
      FileUtils.rm_rf(dlq_dir)
    end

    it "persists DLQ entries to disk" do
      workflow = described_class.new({ action: "fail_always", message: "Test" })

      expect do
        workflow.execute
      end.to raise_error(Fractor::WorkflowExecutionError)

      # Check that file was created
      files = Dir.glob(File.join("tmp/dlq", "*.json"))
      expect(files).not_to be_empty
    end
  end

  describe "DLQ querying" do
    before do
      # Generate some failures and collect DLQs
      @workflows = []
      3.times do |i|
        wf = BasicDLQWorkflow.new({ action: "fail_always",
                                    message: "Test #{i}" })
        begin
          wf.execute
        rescue Fractor::WorkflowExecutionError
          # Expected
        end
        @workflows << wf
      end
    end

    it "filters by error class" do
      # Combine all DLQs from all workflow instances
      all_entries = @workflows.flat_map { |wf| wf.dead_letter_queue&.all || [] }
      workflow_errors = all_entries.select { |e| e.error.is_a?(Fractor::WorkflowExecutionError) }
      expect(workflow_errors.size).to be >= 3
    end

    it "filters by time range" do
      all_entries = @workflows.flat_map { |wf| wf.dead_letter_queue&.all || [] }
      recent = all_entries.select { |e| e.timestamp >= Time.now - 60 }
      expect(recent.size).to be >= 3
    end

    it "supports custom filtering" do
      all_entries = @workflows.flat_map { |wf| wf.dead_letter_queue&.all || [] }
      test_entries = all_entries.select do |entry|
        # Check the work input for the message
        entry.work.input.is_a?(Hash) && entry.work.input[:message]&.include?("Test")
      end
      expect(test_entries.size).to be >= 3
    end

    it "provides statistics" do
      # Each workflow has its own DLQ, check first one
      dlq = @workflows.first.dead_letter_queue
      stats = dlq.stats

      expect(stats[:size]).to eq(1)
      expect(stats[:error_classes]).to include("Fractor::WorkflowExecutionError")
      expect(stats[:oldest_timestamp]).to be_a(Time)
      expect(stats[:newest_timestamp]).to be_a(Time)
    end
  end

  describe "DLQ retry operations" do
    it "can retry single entry" do
      workflow = BasicDLQWorkflow.new({ action: "fail_always",
                                        message: "Test" })

      expect do
        workflow.execute
      end.to raise_error(Fractor::WorkflowExecutionError)

      dlq = workflow.dead_letter_queue
      entry = dlq.all.first
      retry_called = false

      dlq.retry_entry(entry) do |_work, _error, _context|
        retry_called = true
        { status: "retried" }
      end

      expect(retry_called).to be true
    end

    it "can retry all entries" do
      # Create multiple failures and collect DLQs
      workflows = []
      3.times do |i|
        wf = BasicDLQWorkflow.new({ action: "fail_always",
                                    message: "Test #{i}" })
        begin
          wf.execute
        rescue Fractor::WorkflowExecutionError
          # Expected
        end
        workflows << wf
      end

      # Retry entries from all DLQs
      retry_count = 0
      workflows.each do |wf|
        dlq = wf.dead_letter_queue
        dlq.retry_all do |_work, _error, _context|
          retry_count += 1
          { status: "retried" }
        end
      end

      expect(retry_count).to be >= 3
    end
  end

  describe "DLQ management" do
    it "can remove specific entries" do
      workflow = BasicDLQWorkflow.new({ action: "fail_always",
                                        message: "Test" })

      expect do
        workflow.execute
      end.to raise_error(Fractor::WorkflowExecutionError)

      dlq = workflow.dead_letter_queue
      initial_size = dlq.size
      entry = dlq.all.first

      dlq.remove(entry)
      expect(dlq.size).to eq(initial_size - 1)
    end

    it "can clear all entries" do
      # Create multiple failures and collect DLQs
      workflows = []
      3.times do |i|
        wf = BasicDLQWorkflow.new({ action: "fail_always",
                                    message: "Test #{i}" })
        begin
          wf.execute
        rescue Fractor::WorkflowExecutionError
          # Expected
        end
        workflows << wf
      end

      # Check that DLQs have entries
      total_entries = workflows.sum { |wf| wf.dead_letter_queue&.size || 0 }
      expect(total_entries).to be > 0

      # Clear all DLQs
      workflows.each do |wf|
        dlq = wf.dead_letter_queue
        dlq&.clear
      end

      # Verify all are cleared
      total_entries_after = workflows.sum do |wf|
        wf.dead_letter_queue&.size || 0
      end
      expect(total_entries_after).to eq(0)
    end
  end
end
