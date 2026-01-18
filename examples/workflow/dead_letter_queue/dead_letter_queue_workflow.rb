# frozen_string_literal: true

require_relative "../../../lib/fractor"

# Work item for DLQ workflow
class DLQWork < Fractor::Work
  attr_reader :action, :message

  def initialize(action:, message:)
    @action = action
    @message = message
    super({ action:, message: })
  end
end

# Worker that intentionally fails for specific inputs
class UnreliableWorker < Fractor::Worker
  input_type DLQWork
  output_type Hash

  def process(work)
    input = work.input

    # Simulate different failure scenarios
    case input[:action]
    when "fail_always"
      raise StandardError, "Permanent failure: #{input[:message]}"
    when "fail_random"
      raise StandardError, "Random failure" if rand < 0.7
      { status: "success", data: input[:message] }
    when "timeout"
      sleep 10 # Simulate timeout
      { status: "success", data: input[:message] }
    else
      { status: "success", data: input[:message] }
    end
  end
end

# Worker that always succeeds
class ReliableWorker < Fractor::Worker
  input_type Hash
  output_type Hash

  def process(work)
    input = work.input
    { status: "processed", message: input[:message] }
  end
end

# Example 1: Basic Dead Letter Queue with automatic capture
class BasicDLQWorkflow < Fractor::Workflow
  workflow "basic_dlq_workflow" do
    start_with "unreliable_task"
    configure_dead_letter_queue max_size: 1000

    job "unreliable_task" do
      runs_with UnreliableWorker
      inputs_from_workflow

      # Retry up to 3 times with exponential backoff
      retry_on_error max_attempts: 3,
                     backoff: :exponential,
                     initial_delay: 0.1,
                     max_delay: 1

      # Add error handler for logging
      on_error do |error, context|
        puts "Error in unreliable_task: #{error.message}"
      end

      outputs_to_workflow
      terminates_workflow
    end
  end
end

# Example 2: DLQ with custom error handlers
class DLQWithHandlersWorkflow < Fractor::Workflow
  workflow "dlq_with_handlers_workflow" do
    start_with "risky_task"
    configure_dead_letter_queue max_size: 1000

    job "risky_task" do
      runs_with UnreliableWorker
      inputs_from_workflow

      # Retry up to 2 times with linear backoff
      retry_on_error max_attempts: 2,
                     backoff: :linear,
                     initial_delay: 0.1

      # Add error handler for logging
      on_error do |error, _context|
        puts "\n⚠️  Work added to DLQ:"
        puts "   Error: #{error.class.name}: #{error.message}"
        puts "   Timestamp: #{Time.now}"
      end

      outputs_to_workflow
      terminates_workflow
    end
  end
end

# Example 3: DLQ with file persistence
class DLQWithPersistenceWorkflow < Fractor::Workflow
  workflow "dlq_with_persistence_workflow" do
    start_with "persistent_task"
    configure_dead_letter_queue max_size: 1000

    job "persistent_task" do
      runs_with UnreliableWorker
      inputs_from_workflow

      # Retry up to 3 times with exponential backoff
      retry_on_error max_attempts: 3,
                     backoff: :exponential,
                     initial_delay: 0.1

      # Add error handler for persistence simulation
      on_error do |error, _context|
        # Simulate file persistence
        require "fileutils"
        FileUtils.mkdir_p("tmp/dlq")
        entry = {
          error: error.class.name,
          message: error.message,
          timestamp: Time.now.to_s,
        }
        File.write("tmp/dlq/entry_#{Time.now.to_i}.json", entry.to_json)
        puts "DLQ entry persisted to tmp/dlq/"
      end

      outputs_to_workflow
      terminates_workflow
    end
  end
end

# Demonstration runners
if __FILE__ == $PROGRAM_NAME
  require "json"

  puts "=" * 80
  puts "Dead Letter Queue Workflow Examples"
  puts "=" * 80

  # Example 1: Basic DLQ
  puts "\n--- Example 1: Basic Dead Letter Queue ---"
  puts "Running workflow with failing work that exhausts retries..."

  workflow1 = BasicDLQWorkflow.new
  work1 = DLQWork.new(action: "fail_always", message: "Test 1")
  begin
    result1 = workflow1.execute(work1)
    puts "Workflow completed (should not reach here)"
  rescue Fractor::Workflow::WorkflowExecutionError => e
    puts "\n✓ Workflow failed as expected: #{e.message}"
  end

  # Example 2: DLQ with handlers
  puts "\n\n--- Example 2: DLQ with Custom Handlers ---"
  puts "Running workflow with custom notification handlers..."

  workflow2 = DLQWithHandlersWorkflow.new
  work2 = DLQWork.new(action: "fail_always", message: "Test 2")
  begin
    result2 = workflow2.execute(work2)
  rescue Fractor::Workflow::WorkflowExecutionError => e
    puts "\n✓ Workflow failed, handler was triggered above"
  end

  # Example 3: DLQ with persistence
  puts "\n\n--- Example 3: DLQ with File Persistence ---"
  puts "Running workflow with file-persisted DLQ..."

  require "fileutils"
  FileUtils.mkdir_p("tmp/dlq")

  workflow3 = DLQWithPersistenceWorkflow.new
  work3 = DLQWork.new(action: "fail_always", message: "Test 3")
  begin
    result3 = workflow3.execute(work3)
  rescue Fractor::Workflow::WorkflowExecutionError => e
    puts "\n✓ Workflow failed, entry persisted to disk"

    # Check if file was created
    if Dir.exist?("tmp/dlq")
      files = Dir.glob("tmp/dlq/*.json")
      puts "DLQ Size: #{files.size}"
      if files.any?
        puts "First file: #{files.first}"
        content = JSON.parse(File.read(files.first))
        puts "Content: #{content.inspect}"
      end
    end
  end

  # Example 4: Successful execution
  puts "\n\n--- Example 4: Successful Execution ---"
  puts "Running workflow with successful work..."

  workflow4 = BasicDLQWorkflow.new
  work4 = DLQWork.new(action: "success", message: "Success Test")
  begin
    result4 = workflow4.execute(work4)
    puts "\n✓ Workflow completed successfully!"
    puts "Result: #{result4.output.inspect}"
  rescue Fractor::Workflow::WorkflowExecutionError => e
    puts "Workflow failed: #{e.message}"
  end

  puts "\n" + "=" * 80
  puts "Dead Letter Queue examples complete!"
  puts "=" * 80
end
