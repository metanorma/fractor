# frozen_string_literal: true

require_relative "../../../lib/fractor"

# Simulates an unreliable external API
class UnreliableApiWorker < Fractor::Worker
  input_type String
  output_type Hash

  def process(work)
    api_url = work.input

    # Simulate random failures (70% failure rate for demonstration)
    if rand < 0.7
      raise StandardError, "API timeout: #{api_url}"
    end

    # Simulate successful response
    Fractor::WorkResult.new(
      result: {
        status: "success",
        data: { url: api_url, timestamp: Time.now },
      },
      work: work,
    )
  end
end

# Fallback worker that uses cached data
class CachedDataWorker < Fractor::Worker
  input_type String
  output_type Hash

  def process(work)
    api_url = work.input

    # Return cached/default data
    Fractor::WorkResult.new(
      result: {
        status: "cached",
        data: { url: api_url, cached: true, timestamp: Time.now - 3600 },
      },
      work: work,
    )
  end
end

# Process the API response
class ProcessResponseWorker < Fractor::Worker
  input_type Hash
  output_type String

  def process(work)
    response = work.input
    status = response[:status]
    data = response[:data]

    message = if status == "success"
                "Fresh data from #{data[:url]}"
              else
                "Using cached data from #{data[:url]}"
              end

    Fractor::WorkResult.new(result: message, work: work)
  end
end

# Workflow demonstrating retry with exponential backoff
class ExponentialRetryWorkflow < Fractor::Workflow
  workflow "exponential-retry-demo" do
    start_with "fetch_api_data"

    job "fetch_api_data" do
      runs_with UnreliableApiWorker
      inputs_from_workflow

      # Retry up to 3 times with exponential backoff
      retry_on_error max_attempts: 3,
                     backoff: :exponential,
                     initial_delay: 0.5,
                     max_delay: 5

      # Add error handler for logging
      on_error do |error, context|
        puts "Error in fetch_api_data: #{error.message}"
      end

      # Fallback to cached data if all retries fail
      fallback_to "fetch_cached_data"
    end

    job "fetch_cached_data" do
      runs_with CachedDataWorker
      inputs_from_workflow
    end

    job "process_response" do
      runs_with ProcessResponseWorker
      needs "fetch_api_data"
      outputs_to_workflow
    end
  end
end

# Workflow demonstrating retry with linear backoff
class LinearRetryWorkflow < Fractor::Workflow
  workflow "linear-retry-demo" do
    start_with "fetch_api_data"

    job "fetch_api_data" do
      runs_with UnreliableApiWorker
      inputs_from_workflow

      # Retry up to 5 times with linear backoff
      retry_on_error max_attempts: 5,
                     backoff: :linear,
                     initial_delay: 1,
                     increment: 0.5
    end

    job "process_response" do
      runs_with ProcessResponseWorker
      needs "fetch_api_data"
      outputs_to_workflow
    end
  end
end

# Workflow demonstrating retry with constant delay
class ConstantRetryWorkflow < Fractor::Workflow
  workflow "constant-retry-demo" do
    start_with "fetch_api_data"

    job "fetch_api_data" do
      runs_with UnreliableApiWorker
      inputs_from_workflow

      # Retry up to 4 times with constant 1 second delay
      retry_on_error max_attempts: 4,
                     backoff: :constant,
                     delay: 1
    end

    job "process_response" do
      runs_with ProcessResponseWorker
      needs "fetch_api_data"
      outputs_to_workflow
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  puts "=" * 60
  puts "Retry Workflow Examples"
  puts "=" * 60
  puts

  api_url = "https://api.example.com/data"

  puts "1. Exponential Backoff Retry (with fallback)"
  puts "-" * 60
  workflow1 = ExponentialRetryWorkflow.new
  result1 = workflow1.execute(api_url)
  puts "Result: #{result1.output}"
  puts "Status: #{result1.success? ? 'SUCCESS' : 'FAILED'}"
  puts

  puts "2. Linear Backoff Retry"
  puts "-" * 60
  workflow2 = LinearRetryWorkflow.new
  begin
    result2 = workflow2.execute(api_url)
    puts "Result: #{result2.output}"
    puts "Status: #{result2.success? ? 'SUCCESS' : 'FAILED'}"
  rescue Fractor::WorkflowExecutionError => e
    puts "Workflow failed after retries: #{e.message}"
  end
  puts

  puts "3. Constant Delay Retry"
  puts "-" * 60
  workflow3 = ConstantRetryWorkflow.new
  begin
    result3 = workflow3.execute(api_url)
    puts "Result: #{result3.output}"
    puts "Status: #{result3.success? ? 'SUCCESS' : 'FAILED'}"
  rescue Fractor::WorkflowExecutionError => e
    puts "Workflow failed after retries: #{e.message}"
  end
  puts

  puts "=" * 60
  puts "Examples complete"
  puts "=" * 60
end
