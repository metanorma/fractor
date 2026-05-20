#!/usr/bin/env ruby
# frozen_string_literal: true

# This script sets up a Fractor supervisor with long-running jobs
# Used for testing Ctrl+C (SIGINT) handling

require "bundler/setup"
require "fractor"

# Long-running worker that sleeps for specified time
class LongRunningWorker < Fractor::Worker
  def process(work)
    sleep_seconds = work.input[:sleep_time]
    puts "Worker #{@name}: Starting long-running task for #{sleep_seconds} seconds" if ENV["FRACTOR_DEBUG"]

    # Start a long sleep
    start_time = Time.now
    while (Time.now - start_time) < sleep_seconds
      # Check every 0.1 seconds to allow for interruption
      sleep(0.1)
    end

    puts "Worker #{@name}: Long-running task completed" if ENV["FRACTOR_DEBUG"]
    Fractor::WorkResult.new(
      result: "Processed sleep for #{sleep_seconds} seconds", work: work,
    )
  end
end

# Create a simple Work class for our long-running task
class SleepWork < Fractor::Work
  def initialize(seconds)
    super({ sleep_time: seconds })
  end
end

# For testing purposes, we need to see these messages regardless of FRACTOR_DEBUG
# since this is a test script, not part of the library itself
puts "Starting Fractor with long-running work..."

# Setup Fractor supervisor with our worker
supervisor = Fractor::Supervisor.new(
  worker_pools: [
    { worker_class: LongRunningWorker, num_workers: 2 },
  ],
)

# Add work items that will sleep for 10 seconds each
supervisor.add_work_item(SleepWork.new(10))
supervisor.add_work_item(SleepWork.new(10))

# Print process ID for testing purposes and ensure it's flushed immediately
# This is critical for the test to work - it needs to capture the PID
puts "Process ID: #{Process.pid}"
$stdout.flush

# Run the supervisor - should be interruptible by Ctrl+C/SIGINT
supervisor.run

puts "Supervisor completed normally" if ENV["FRACTOR_DEBUG"]
