# frozen_string_literal: true

require_relative "../spec_helper"
require "benchmark/ips"

# Benchmark workflow execution patterns
#
# Usage:
#   ruby spec/benchmarks/workflow_benchmark.rb

module Fractor
  module Benchmarks
    class WorkflowBenchmark
      # Simple worker for benchmarking
      class BenchWorker < Fractor::Worker
        def process(work)
          # Simulate some work
          result = work.input[:value] * 2
          Fractor::WorkResult.new(result: result, work: work)
        end
      end

      # Transform worker for pipeline benchmarks
      class TransformWorker < Fractor::Worker
        def process(work)
          result = work.input[:data].upcase
          Fractor::WorkResult.new(result: result, work: work)
        end
      end

      # Filter worker for pipeline benchmarks
      class FilterWorker < Fractor::Worker
        def process(work)
          result = work.input[:data].length > 5
          Fractor::WorkResult.new(result: result, work: work)
        end
      end

      def run
        puts "=" * 80
        puts "Workflow Execution Benchmarks"
        puts "=" * 80
        puts

        benchmark_simple_workflow
        benchmark_linear_workflow
        benchmark_fanout_workflow
        benchmark_workflow_with_retry
      end

      private

      def benchmark_simple_workflow
        puts "Simple Workflow (single job, 100 items)"
        puts "-" * 80

        Benchmark.ips do |x|
          x.config(time: 5, warmup: 2)

          x.report("simple workflow") do
            workflow = Fractor::Workflow.define("simple") do
              job :process, BenchWorker
            end

            items = Array.new(100) { |i| { value: i } }
            workflow.new.execute(items)
          end
        end
        puts
      end

      def benchmark_linear_workflow
        puts "Linear Workflow (3 jobs in sequence, 100 items)"
        puts "-" * 80

        Benchmark.ips do |x|
          x.config(time: 5, warmup: 2)

          x.report("linear workflow") do
            workflow = Fractor::Workflow.chain("linear")
              .step(:step1, BenchWorker)
              .step(:step2, BenchWorker)
              .step(:step3, BenchWorker)
              .build

            items = Array.new(100) { |i| { value: i } }
            workflow.new.execute(items)
          end
        end
        puts
      end

      def benchmark_fanout_workflow
        puts "Fan-out Workflow (1 -> 3 parallel jobs, 100 items)"
        puts "-" * 80

        Benchmark.ips do |x|
          x.config(time: 5, warmup: 2)

          x.report("fan-out workflow") do
            workflow = Fractor::Workflow.define("fanout") do
              job :source, BenchWorker
              job :branch1, BenchWorker, needs: :source
              job :branch2, BenchWorker, needs: :source
              job :branch3, BenchWorker, needs: :source
            end

            items = Array.new(100) { |i| { value: i } }
            workflow.new.execute(items)
          end
        end
        puts
      end

      def benchmark_workflow_with_retry
        puts "Workflow with Retry Logic (occasional failures)"
        puts "-" * 80

        # Worker that fails occasionally
        failing_worker = Class.new(Fractor::Worker) do
          @@count = 0

          def process(work)
            @@count += 1
            # Fail every 10th item on first attempt
            if @@count % 10 == 0 && work.input[:attempt].nil?
              work.input[:attempt] = 1
              raise "Simulated failure"
            end

            result = work.input[:value] * 2
            Fractor::WorkResult.new(result: result, work: work)
          end
        end

        Benchmark.ips do |x|
          x.config(time: 5, warmup: 2)

          x.report("workflow with retry") do
            workflow = Fractor::Workflow.define("retry") do
              job :process, failing_worker do
                retry_on_error max_attempts: 2,
                               backoff: :constant,
                               delay: 0.001
              end
            end

            items = Array.new(100) { |i| { value: i } }
            workflow.new.execute(items)
          end
        end
        puts
      end
    end
  end
end

# Run benchmarks if executed directly
if __FILE__ == $PROGRAM_NAME
  Fractor::Benchmarks::WorkflowBenchmark.new.run
end
