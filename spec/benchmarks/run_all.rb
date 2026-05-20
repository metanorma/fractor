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
        run_workflow_benchmarks
        run_worker_scaling_benchmarks
        run_queue_benchmarks
        run_memory_benchmarks

        print_summary
      end

      private

      def run_workflow_benchmarks
        WorkflowBenchmark.new.run
      rescue StandardError
      end

      def run_worker_scaling_benchmarks
        WorkerScalingBenchmark.new.run
      rescue StandardError
      end

      def run_queue_benchmarks
        QueueBenchmark.new.run
      rescue StandardError
      end

      def run_memory_benchmarks
        MemoryBenchmark.new.run
      rescue StandardError
      end

      def print_summary; end
    end
  end
end

# Run all benchmarks if executed directly
if __FILE__ == $PROGRAM_NAME
  Fractor::Benchmarks::BenchmarkRunner.new.run
end
