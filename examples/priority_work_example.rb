#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "../lib/fractor"

# Example demonstrating priority-based work processing
# This shows how to use PriorityWork and PriorityWorkQueue for
# processing tasks based on their priority levels

# Define a worker that processes priority work
class PriorityWorker < Fractor::Worker
  def process(work)
    # Simulate work processing
    sleep 0.1

    result = "Processed #{work.input[:task]} " \
             "(priority: #{work.priority}, age: #{work.age.round(2)}s)"

    Fractor::WorkResult.new(result: result, work: work)
  end
end

puts "=" * 60
puts "Priority Work Example"
puts "=" * 60
puts

# Example 1: Basic Priority Queue
puts "Example 1: Basic Priority Ordering"
puts "-" * 60

queue = Fractor::PriorityWorkQueue.new

# Add work items with different priorities
queue.push(Fractor::PriorityWork.new({ task: "Background report" }, priority: :background))
queue.push(Fractor::PriorityWork.new({ task: "Critical bug fix" }, priority: :critical))
queue.push(Fractor::PriorityWork.new({ task: "Normal feature" }, priority: :normal))
queue.push(Fractor::PriorityWork.new({ task: "High priority task" }, priority: :high))
queue.push(Fractor::PriorityWork.new({ task: "Low priority cleanup" }, priority: :low))

puts "Queue statistics:"
stats = queue.stats
puts "  Total items: #{stats[:total]}"
puts "  By priority: #{stats[:by_priority]}"
puts

puts "Processing in priority order:"
5.times do
  work = queue.pop_non_blocking
  puts "  #{work.input[:task]} (#{work.priority})"
end
puts

# Example 2: Priority Aging
puts "Example 2: Priority Aging (Preventing Starvation)"
puts "-" * 60

aged_queue = Fractor::PriorityWorkQueue.new(
  aging_enabled: true,
  aging_threshold: 2  # 2 seconds
)

# Add a low-priority item first
aged_queue.push(Fractor::PriorityWork.new(
  { task: "Old low-priority task" },
  priority: :low
))

puts "Added low-priority task at #{Time.now.strftime('%H:%M:%S')}"
puts "Waiting 3 seconds to let it age..."
sleep 3

# Add high-priority items after the low-priority one has aged
aged_queue.push(Fractor::PriorityWork.new(
  { task: "New high-priority task" },
  priority: :high
))

puts "Added high-priority task at #{Time.now.strftime('%H:%M:%S')}"
puts

puts "Processing order with aging enabled:"
2.times do
  work = aged_queue.pop_non_blocking
  puts "  #{work.input[:task]} " \
       "(priority: #{work.priority}, age: #{work.age.round(1)}s)"
end
puts "Note: The aged low-priority task was processed first!"
puts

# Example 3: Using with Supervisor
puts "Example 3: Integration with Supervisor"
puts "-" * 60

priority_queue = Fractor::PriorityWorkQueue.new

# Add mixed priority work
[
  { task: "Process payment", priority: :critical },
  { task: "Send email", priority: :normal },
  { task: "Generate report", priority: :low },
  { task: "Update inventory", priority: :high },
  { task: "Cleanup cache", priority: :background }
].each do |item|
  priority_queue.push(Fractor::PriorityWork.new(item, priority: item[:priority]))
end

# Create supervisor with priority queue
supervisor = Fractor::Supervisor.new(
  work_queue: priority_queue,
  worker_pools: [
    { worker_class: PriorityWorker, num_workers: 2 }
  ]
)

puts "Processing #{priority_queue.size} tasks with 2 workers..."
supervisor.start

# Wait for all work to complete
sleep 1 until priority_queue.empty?

supervisor.shutdown
results = supervisor.results

puts "\nResults (in completion order):"
results.each_with_index do |result, i|
  puts "  #{i + 1}. #{result.result}"
end
puts

# Example 4: Queue Statistics
puts "Example 4: Monitoring Queue Statistics"
puts "-" * 60

stats_queue = Fractor::PriorityWorkQueue.new

# Add various priority items
10.times do |i|
  priority = [:critical, :high, :normal, :low, :background].sample
  stats_queue.push(Fractor::PriorityWork.new({ id: i }, priority: priority))
end

stats = stats_queue.stats
puts "Queue statistics:"
puts "  Total items: #{stats[:total]}"
puts "  Closed: #{stats[:closed]}"
puts "  Items by priority:"
stats[:by_priority].each do |priority, count|
  puts "    #{priority}: #{count}"
end
puts

puts "=" * 60
puts "Priority Work Examples Complete"
puts "=" * 60
