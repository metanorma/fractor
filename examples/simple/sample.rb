#!/usr/bin/env ruby
# frozen_string_literal: true

# =============================================================================
# Simple Example - Getting Started with Fractor
# =============================================================================
#
# This example demonstrates the basic usage of the Fractor framework.
#
# WHAT THIS DEMONSTRATES:
# - How to create a Work class (MyWork) to encapsulate work items
# - How to create a Worker class (MyWorker) to process work
# - How to set up a Supervisor to manage parallel processing
# - Basic error handling in workers
# - How to access and display results after processing
# - Auto-detection of available processors (num_workers not specified)
#
# KEY CONCEPTS:
# 1. Work Class: Inherits from Fractor::Work, stores input data
# 2. Worker Class: Inherits from Fractor::Worker, implements process() method
# 3. Supervisor: Manages worker Ractors and distributes work
# 4. WorkResult: Contains either successful results or errors
#
# HOW TO RUN:
#   ruby examples/simple/sample.rb
#
# WHAT TO EXPECT:
# - Creates work items with values 1-10
# - Processes them in parallel using auto-detected number of workers
# - Value 5 intentionally produces an error for demonstration
# - Displays successful results and error information
#
# =============================================================================

require_relative "../../lib/fractor"

# Client-specific work item implementation inheriting from Fractor::Work
class MyWork < Fractor::Work
  # Constructor storing all data in the input hash
  def initialize(value)
    super({ value: value })
  end

  def value
    input[:value]
  end

  def to_s
    "MyWork: #{value}"
  end
end

# Another work type for demonstrating multiple work types
class OtherWork < Fractor::Work
  # Constructor storing all data in the input hash
  def initialize(value)
    super({ value: value })
  end

  def value
    input[:value]
  end

  def to_s
    "OtherWork: #{value}"
  end
end

# Client-specific worker implementation inheriting from Fractor::Worker
class MyWorker < Fractor::Worker
  # This method is called by the Ractor to process the work
  # It should return a Fractor::WorkResult object
  def process(work)
    # Only print debug information if FRACTOR_DEBUG is enabled
    puts "Working on '#{work.inspect}'" if ENV["FRACTOR_DEBUG"]

    # Check work type and handle accordingly
    if work.is_a?(MyWork)
      if work.value == 5
        # Return a Fractor::WorkResult for errors
        # Store the error object, not just the string
        error = StandardError.new("Cannot process value 5")
        return Fractor::WorkResult.new(error: error, work: work)
      end

      calculated = work.value * 2
      # Return a Fractor::WorkResult for success
      Fractor::WorkResult.new(result: calculated, work: work)
    elsif work.is_a?(OtherWork)
      # Process OtherWork differently
      Fractor::WorkResult.new(result: "Processed: #{work.value}", work: work)
    else
      # Handle unexpected work types - create a proper error object
      error = TypeError.new("Unsupported work type: #{work.class}")
      Fractor::WorkResult.new(error: error, work: work)
    end
  end
end

# --- Main Execution ---
# This section demonstrates how to use the Fractor framework with custom
# MyWorker and MyWork classes.
if __FILE__ == $PROGRAM_NAME
  # Create supervisor, passing the client-specific worker class in a worker pool
  # Note: num_workers is not specified, so it will auto-detect the number of available processors
  supervisor = Fractor::Supervisor.new(
    worker_pools: [
      { worker_class: MyWorker } # Worker class without explicit num_workers uses auto-detection
    ]
  )

  # Create Work objects and add them to the supervisor
  work_items = (1..10).map { |i| MyWork.new(i) }
  supervisor.add_work_items(work_items)

  # Run the supervisor to start processing work
  supervisor.run

  puts "Processing complete."
  puts "Final Aggregated Results:"
  # Access the results aggregator from the supervisor
  puts supervisor.results.inspect

  # Print failed items directly from the Fractor::ResultAggregator's errors array
  failed_items = supervisor.results.errors # Access the errors array
  puts "\nFailed Work Items (#{failed_items.size}):"

  # Display error information properly using the error object
  failed_items.each do |error_result|
    puts "Work: #{error_result.work.inspect}"
    puts "Error: #{error_result.error.class}: #{error_result.error.message}"
  end
end
