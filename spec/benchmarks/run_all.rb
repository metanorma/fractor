# frozen_string_literal: true

require_relative "workflow_benchmark"
require_relative "worker_scaling_benchmark"
require_relative "queue_benchmark"
require_relative "memory_benchmark"

# Main benchmark runner
#
# Runs all benchmark suites and generates a comprehensive report
#
# Usage:
#   ruby spec/benchmarks/run_all.rb

module Fractor
  module Benchmarks
    class BenchmarkRunner
      def run
        puts
        puts "=" * 80
        puts "FRACTOR COMPREHENSIVE BENCHMARK SUITE"
        puts "=" * 80
        puts "Ruby version: #{RUBY_VERSION}"
        puts "Fractor version: #{Fractor::VERSION}"
        puts "Timestamp: #{Time.now}"
        puts "=" * 80
        puts

        run_workflow_benchmarks
        run_worker_scaling_benchmarks
        run_queue_benchmarks
        run_memory_benchmarks

        print_summary
      end

      private

      def run_workflow_benchmarks
        puts "\n\n"
        puts "###" * 26
        puts "### WORKFLOW BENCHMARKS"
        puts "###" * 26
        puts

        WorkflowBenchmark.new.run
      rescue StandardError => e
        puts "ERROR in Workflow Benchmarks: #{e.message}"
        puts e.backtrace.first(5)
      end

      def run_worker_scaling_benchmarks
        puts "\n\n"
        puts "###" * 26
        puts "### WORKER SCALING BENCHMARKS"
        puts "###" * 26
        puts

        WorkerScalingBenchmark.new.run
      rescue StandardError => e
        puts "ERROR in Worker Scaling Benchmarks: #{e.message}"
        puts e.backtrace.first(5)
      end

      def run_queue_benchmarks
        puts "\n\n"
        puts "###" * 26
        puts "### QUEUE BENCHMARKS"
        puts "###" * 26
        puts

        QueueBenchmark.new.run
      rescue StandardError => e
        puts "ERROR in Queue Benchmarks: #{e.message}"
        puts e.backtrace.first(5)
      end

      def run_memory_benchmarks
        puts "\n\n"
        puts "###" * 26
        puts "### MEMORY BENCHMARKS"
        puts "###" * 26
        puts

        MemoryBenchmark.new.run
      rescue StandardError => e
        puts "ERROR in Memory Benchmarks: #{e.message}"
        puts e.backtrace.first(5)
      end

      def print_summary
        puts "\n\n"
        puts "=" * 80
        puts "BENCHMARK SUITE COMPLETE"
        puts "=" * 80
        puts
        puts "All benchmarks completed successfully!"
        puts
        puts "Next steps:"
        puts "  1. Review results above for performance baselines"
        puts "  2. Run individual benchmarks for detailed analysis:"
        puts "     ruby spec/benchmarks/workflow_benchmark.rb"
        puts "     ruby spec/benchmarks/worker_scaling_benchmark.rb"
        puts "     ruby spec/benchmarks/queue_benchmark.rb"
        puts "     ruby spec/benchmarks/memory_benchmark.rb"
        puts "  3. Compare results after optimizations"
        puts
      end
    end
  end
end

# Run all benchmarks if executed directly
if __FILE__ == $PROGRAM_NAME
  Fractor::Benchmarks::BenchmarkRunner.new.run
end
