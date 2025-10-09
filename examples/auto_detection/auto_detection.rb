#!/usr/bin/env ruby
# frozen_string_literal: true

# =============================================================================
# Auto-Detection Example
# =============================================================================
#
# This example demonstrates Fractor's automatic worker detection feature.
#
# WHAT THIS DEMONSTRATES:
# - How Fractor automatically detects the number of available processors
# - Comparison between auto-detection and explicit worker configuration
# - Mixed configuration (some pools with auto-detection, some explicit)
# - How to verify the number of workers being used
#
# WHEN TO USE AUTO-DETECTION:
# - For portable code that adapts to different environments
# - When you want optimal resource utilization without manual tuning
# - For development where the number of cores varies across machines
#
# WHEN TO SET EXPLICIT VALUES:
# - When you need precise control over resource usage
# - For production environments with specific requirements
# - When limiting workers due to memory or other constraints
#
# HOW TO RUN:
#   ruby examples/auto_detection/auto_detection.rb
#
# WHAT TO EXPECT:
# - The script will show how many processors were auto-detected
# - It will create workers based on detection vs explicit configuration
# - Results will be processed in parallel across all workers
#
# =============================================================================

require_relative "../../lib/fractor"
require "etc"

# Simple work class for demonstration
class ComputeWork < Fractor::Work
  def initialize(value)
    super({ value: value })
  end

  def value
    input[:value]
  end

  def to_s
    "ComputeWork: #{value}"
  end
end

# Simple worker that squares numbers
class ComputeWorker < Fractor::Worker
  def process(work)
    result = work.value * work.value
    Fractor::WorkResult.new(result: result, work: work)
  rescue StandardError => e
    Fractor::WorkResult.new(error: e, work: work)
  end
end

# =============================================================================
# DEMONSTRATION
# =============================================================================

puts "=" * 80
puts "Fractor Auto-Detection Example"
puts "=" * 80
puts

# Show system information
num_processors = Etc.nprocessors
puts "System Information:"
puts "  Available processors: #{num_processors}"
puts

# Example 1: Auto-detection (recommended for most cases)
puts "-" * 80
puts "Example 1: Auto-Detection"
puts "-" * 80
puts "Creating supervisor WITHOUT specifying num_workers..."
puts "Fractor will automatically detect and use #{num_processors} workers"
puts

supervisor1 = Fractor::Supervisor.new(
  worker_pools: [
    { worker_class: ComputeWorker }, # No num_workers specified
  ],
)

# Add work items
work_items = (1..10).map { |i| ComputeWork.new(i) }
supervisor1.add_work_items(work_items)

puts "Processing 10 work items with auto-detected workers..."
supervisor1.run

puts "Results: #{supervisor1.results.results.map(&:result).sort.join(', ')}"
puts "✓ Auto-detection successful!"
puts

# Example 2: Explicit configuration
puts "-" * 80
puts "Example 2: Explicit Configuration"
puts "-" * 80
puts "Creating supervisor WITH explicit num_workers=4..."
puts

supervisor2 = Fractor::Supervisor.new(
  worker_pools: [
    { worker_class: ComputeWorker, num_workers: 4 },
  ],
)

supervisor2.add_work_items((11..20).map { |i| ComputeWork.new(i) })

puts "Processing 10 work items with 4 explicitly configured workers..."
supervisor2.run

puts "Results: #{supervisor2.results.results.map(&:result).sort.join(', ')}"
puts "✓ Explicit configuration successful!"
puts

# Example 3: Mixed configuration
puts "-" * 80
puts "Example 3: Mixed Auto-Detection and Explicit Configuration"
puts "-" * 80
puts "Creating supervisor with multiple worker pools:"
puts "  - Pool 1: Auto-detected workers"
puts "  - Pool 2: 2 explicitly configured workers"
puts

supervisor3 = Fractor::Supervisor.new(
  worker_pools: [
    { worker_class: ComputeWorker }, # Auto-detected
    { worker_class: ComputeWorker, num_workers: 2 }, # Explicit
  ],
)

supervisor3.add_work_items((21..30).map { |i| ComputeWork.new(i) })

puts "Processing 10 work items with mixed configuration..."
supervisor3.run

puts "Results: #{supervisor3.results.results.map(&:result).sort.join(', ')}"
puts "✓ Mixed configuration successful!"
puts

# Summary
puts "=" * 80
puts "Summary"
puts "=" * 80
puts
puts "Auto-detection provides:"
puts "  ✓ Automatic adaptation to different environments"
puts "  ✓ Optimal resource utilization by default"
puts "  ✓ Less configuration needed"
puts "  ✓ Portability across machines with different CPU counts"
puts
puts "Explicit configuration provides:"
puts "  ✓ Precise control over worker count"
puts "  ✓ Ability to limit resource usage"
puts "  ✓ Predictable behavior in production"
puts
puts "Best practice: Use auto-detection for development and testing,"
puts "               then tune explicitly for production if needed."
puts
puts "=" * 80
