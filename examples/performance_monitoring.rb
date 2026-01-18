# frozen_string_literal: true

require_relative "../lib/fractor"
require_relative "../lib/fractor/performance_monitor"

# Example worker that simulates varying processing times
class VariableLatencyWorker
  def self.perform(work)
    # Simulate variable work latency
    sleep(rand * 0.1) # 0-100ms

    result = work.payload[:value] * 2
    Fractor::WorkResult.new(result: result, work: work)
  end
end

# Example: Basic Performance Monitoring
puts "=" * 80
puts "Performance Monitoring Example"
puts "=" * 80

# Create supervisor with multiple workers
supervisor = Fractor::Supervisor.new(
  worker_pools: [
    { worker_class: VariableLatencyWorker, num_workers: 4 },
  ],
)

# Create and start performance monitor
monitor = Fractor::PerformanceMonitor.new(supervisor, sample_interval: 0.5)
monitor.start

puts "\nProcessing 100 work items..."
puts "Monitor started, sampling every 0.5 seconds"

# Add work items
100.times do |i|
  supervisor.add_work_item(Fractor::Work.new({ value: i }))
end

# Run the supervisor
supervisor_thread = Thread.new { supervisor.run }

# Wait for completion
sleep 0.5 while supervisor.work_queue.size > 0 || supervisor.results.results.size < 100

# Stop monitoring
monitor.stop
supervisor.stop
supervisor_thread.join

puts "\n" + "=" * 80
puts "Human-Readable Report"
puts "=" * 80
puts monitor.report

puts "\n" + "=" * 80
puts "JSON Export"
puts "=" * 80
puts JSON.pretty_generate(JSON.parse(monitor.to_json))

puts "\n" + "=" * 80
puts "Prometheus Metrics"
puts "=" * 80
puts monitor.to_prometheus

puts "\n" + "=" * 80
puts "Example: Real-time Monitoring with Manual Recording"
puts "=" * 80

# Create a new monitor
supervisor2 = Fractor::Supervisor.new(
  worker_pools: [
    { worker_class: VariableLatencyWorker, num_workers: 2 },
  ],
)

monitor2 = Fractor::PerformanceMonitor.new(supervisor2)
monitor2.start

puts "\nManually recording job completions..."

# Simulate job execution and manually record metrics
10.times do |i|
  start_time = Time.now

  # Simulate work
  sleep(rand * 0.05)

  # Record the job
  latency = Time.now - start_time
  success = rand > 0.1 # 90% success rate

  monitor2.record_job(latency, success: success)

  print "." if i % 10 == 0
end

monitor2.stop

puts "\n\nFinal Metrics:"
snapshot = monitor2.snapshot
puts "  Jobs Processed: #{snapshot[:jobs_processed]}"
puts "  Success Rate: #{(snapshot[:jobs_succeeded].to_f / snapshot[:jobs_processed] * 100).round(2)}%"
puts "  Average Latency: #{(snapshot[:average_latency] * 1000).round(2)}ms"
puts "  P95 Latency: #{(snapshot[:p95_latency] * 1000).round(2)}ms"
puts "  Throughput: #{snapshot[:throughput].round(2)} jobs/sec"

puts "\n" + "=" * 80
puts "Example Complete"
puts "=" * 80
puts "\nPerformance monitoring provides:"
puts "  ✓ Jobs processed counter"
puts "  ✓ Latency tracking (average, p50, p95, p99)"
puts "  ✓ Throughput calculation (jobs/second)"
puts "  ✓ Worker utilization tracking"
puts "  ✓ Queue depth monitoring"
puts "  ✓ Memory usage tracking"
puts "  ✓ JSON export"
puts "  ✓ Prometheus metrics export"
