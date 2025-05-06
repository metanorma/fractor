#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "fractor"

# Client-specific worker implementation inheriting from Fractor::Worker
class MyWorker < Fractor::Worker
  # This method is called by the Ractor to process the work
  # It should return a Fractor::WorkResult object
  # If there is an error, it should raise an exception
  # The Ractor will catch the exception and send it back to the main thread
  def process(work)
    puts "Working on '#{work.inspect}'"

    if work.input == 5
      # Return a Fractor::WorkResult for errors
      return Fractor::WorkResult.new(error: "Error processing work #{work.input}", work: work)
    end

    calculated = work.input * 2
    # Return a Fractor::WorkResult for success
    Fractor::WorkResult.new(result: calculated, work: work)
  end
end

# Client-specific work item implementation inheriting from Fractor::Work
class MyWork < Fractor::Work
  def to_s
    "MyWork: #{@input}"
  end
end

# --- Main Execution ---
# This section demonstrates how to use the Fractor framework with custom
# MyWorker and MyWork classes.
if __FILE__ == $PROGRAM_NAME
  # Create supervisor, passing the client-specific worker and work classes
  supervisor = Fractor::Supervisor.new(
    worker_class: MyWorker,
    work_class: MyWork,
    num_workers: 2 # Specify the number of worker Ractors
  )

  # Add work items (raw data) - the Supervisor will wrap these in MyWork objects
  work_items = (1..10).to_a
  supervisor.add_work(work_items)

  # Run the supervisor to start processing work
  supervisor.run

  puts "Processing complete."
  puts "Final Aggregated Results:"
  # Access the results aggregator from the supervisor
  puts supervisor.results.inspect

  # Print failed items directly from the Fractor::ResultAggregator's errors array
  failed_items = supervisor.results.errors # Access the errors array
  puts "\nFailed Work Items (#{failed_items.size}):"
  # Display each Fractor::WorkResult object in the errors array
  puts failed_items.map(&:to_s).join("\n") # Use to_s on the WorkResult objects
end
