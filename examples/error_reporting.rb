# frozen_string_literal: true

require_relative "../lib/fractor"
require_relative "../lib/fractor/error_reporter"

# Example demonstrating comprehensive error reporting and analytics
#
# This example shows how to:
# 1. Set up an ErrorReporter to track errors
# 2. Record successes and failures
# 3. Generate comprehensive error reports
# 4. Export metrics to Prometheus format
# 5. Set up error handlers for real-time notifications

# Simulate various types of workers
class NetworkWorker < Fractor::Worker
  def process(work)
    # Simulate network errors
    if work.input[:fail]
      Fractor::WorkResult.new(
        error: SocketError.new("Connection refused"),
        error_code: :connection_refused,
        error_context: { endpoint: work.input[:endpoint], attempt: 1 },
        work: work,
      )
    else
      Fractor::WorkResult.new(result: "Data fetched", work: work)
    end
  end
end

class ValidationWorker < Fractor::Worker
  def process(work)
    # Simulate validation errors
    if work.input[:invalid]
      Fractor::WorkResult.new(
        error: ArgumentError.new("Invalid input"),
        error_code: :validation_failed,
        error_context: { field: "email", value: work.input[:value] },
        work: work,
      )
    else
      Fractor::WorkResult.new(result: "Valid", work: work)
    end
  end
end

class CriticalWorker < Fractor::Worker
  def process(work)
    # Simulate critical errors
    if work.input[:critical]
      Fractor::WorkResult.new(
        error: SystemStackError.new("Stack overflow"),
        error_severity: :critical,
        error_context: { stack_depth: 10000 },
        work: work,
      )
    else
      Fractor::WorkResult.new(result: "Success", work: work)
    end
  end
end

puts "=" * 80
puts "Error Reporting Example"
puts "=" * 80
puts ""

# Initialize error reporter
reporter = Fractor::ErrorReporter.new

# Set up error handler for real-time notifications
reporter.on_error do |work_result, job_name|
  if work_result.critical?
    puts "🚨 CRITICAL ERROR DETECTED!"
    puts "   Job: #{job_name || 'unknown'}"
    puts "   Error: #{work_result.error.message}"
    puts ""
  end
end

puts "1. Recording various work results..."
puts "-" * 80

# Simulate successful work
5.times do |i|
  work = Fractor::Work.new({ endpoint: "api.example.com", id: i })
  result = NetworkWorker.new.process(work)
  reporter.record(result, job_name: "network_job")
end
puts "✓ Recorded 5 successful network operations"

# Simulate network errors
3.times do |i|
  work = Fractor::Work.new({ fail: true, endpoint: "api.example.com", id: i })
  result = NetworkWorker.new.process(work)
  reporter.record(result, job_name: "network_job")
end
puts "✗ Recorded 3 network errors"

# Simulate validation errors
4.times do |i|
  work = Fractor::Work.new({ invalid: true, value: "bad-email-#{i}" })
  result = ValidationWorker.new.process(work)
  reporter.record(result, job_name: "validation_job")
end
puts "✗ Recorded 4 validation errors"

# Simulate critical error
work = Fractor::Work.new({ critical: true })
result = CriticalWorker.new.process(work)
reporter.record(result, job_name: "critical_job")
puts "🚨 Recorded 1 critical error"

# Add some successful validations
3.times do |i|
  work = Fractor::Work.new({ valid: true, value: "good-email-#{i}@example.com" })
  result = ValidationWorker.new.process(work)
  reporter.record(result, job_name: "validation_job")
end
puts "✓ Recorded 3 successful validations"

puts ""
puts "2. Overall Statistics"
puts "-" * 80
puts "Total Successes: #{reporter.total_successes}"
puts "Total Errors:    #{reporter.total_errors}"
puts "Error Rate:      #{reporter.overall_error_rate}%"
puts ""

puts "3. Top Error Categories"
puts "-" * 80
reporter.top_categories.each do |category, count|
  puts "#{category.to_s.ljust(15)}: #{count} errors"
end
puts ""

puts "4. Top Error Jobs"
puts "-" * 80
reporter.top_jobs.each do |job, count|
  puts "#{job.to_s.ljust(20)}: #{count} errors"
end
puts ""

puts "5. Critical Errors"
puts "-" * 80
critical = reporter.critical_errors
if critical.empty?
  puts "No critical errors"
else
  critical.each do |error_info|
    puts "Category: #{error_info[:category]}"
    puts "Count:    #{error_info[:count]}"
    puts "Recent:"
    error_info[:recent].each do |err|
      puts "  - #{err[:error_class]}: #{err[:error_message]}"
    end
  end
end
puts ""

puts "6. Errors by Severity"
puts "-" * 80
reporter.errors_by_severity.each do |severity, count|
  icon = case severity
         when :critical then "🚨"
         when :error then "❌"
         when :warning then "⚠️"
         else "ℹ️"
         end
  puts "#{icon} #{severity.to_s.ljust(10)}: #{count}"
end
puts ""

puts "7. Job-Specific Statistics"
puts "-" * 80
reporter.top_jobs.each_key do |job_name|
  stats = reporter.job_stats(job_name)
  puts "Job: #{job_name}"
  puts "  Total Errors:     #{stats[:total_count]}"
  puts "  Error Rate:       #{stats[:error_rate]}/s"
  puts "  Most Common Code: #{stats[:most_common_code]}"
  puts "  Highest Severity: #{stats[:highest_severity]}"
  puts "  Trend:            #{stats[:trending]}"
  puts ""
end

puts "8. Formatted Text Report"
puts "-" * 80
puts ""
puts reporter.formatted_report
puts ""

puts "9. Prometheus Metrics Export"
puts "-" * 80
puts reporter.to_prometheus
puts ""

puts "10. JSON Export"
puts "-" * 80
require "json"
puts JSON.pretty_generate(reporter.report)
puts ""

puts "=" * 80
puts "Example completed successfully!"
puts "=" * 80
