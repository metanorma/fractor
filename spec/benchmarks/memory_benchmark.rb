# frozen_string_literal: true

require_relative "../spec_helper"

# Benchmark memory usage patterns
#
# Tests memory consumption and leak detection for various workloads
#
# Usage:
#   ruby spec/benchmarks/memory_benchmark.rb

module Fractor
  module Benchmarks
    class MemoryBenchmark
      # Simple worker for memory tests
      class SimpleWorker < Fractor::Worker
        def process(work)
          result = work.input[:value] * 2
          Fractor::WorkResult.new(result: result, work: work)
        end
      end

      # Worker that allocates memory
      class MemoryIntensiveWorker < Fractor::Worker
        def process(work)
          # Allocate some memory
          data = Array.new(1000) { |i| "data_#{i}" * 10 }
          result = data.size
          Fractor::WorkResult.new(result: result, work: work)
        end
      end

      def run
        benchmark_baseline_memory
        benchmark_supervisor_memory
        benchmark_workflow_memory
        benchmark_memory_leak_detection
      end

      private

      def current_memory_mb
        `ps -o rss= -p #{Process.pid}`.to_i / 1024.0
      end

      def benchmark_baseline_memory
        GC.start
        current_memory_mb
      end

      def benchmark_supervisor_memory
        GC.start
        before_memory = current_memory_mb

        supervisor = Fractor::Supervisor.new(
          worker_pools: [{
            worker_class: SimpleWorker,
            num_workers: 4,
          }],
        )

        work_items = Array.new(1000) do |i|
          Fractor::Work.new(value: i)
        end

        supervisor.add_work_items(work_items)
        supervisor.run

        after_memory = current_memory_mb
        after_memory - before_memory
      end

      def benchmark_workflow_memory
        GC.start
        before_memory = current_memory_mb

        workflow = Fractor::Workflow.chain("memory-test")
          .step(:step1, SimpleWorker)
          .step(:step2, SimpleWorker)
          .step(:step3, SimpleWorker)
          .build

        items = Array.new(1000) { |i| { value: i } }
        workflow.new.execute(items)

        after_memory = current_memory_mb
        after_memory - before_memory
      end

      def benchmark_memory_leak_detection
        memory_samples = []

        10.times do |_iteration|
          GC.start
          before_memory = current_memory_mb

          supervisor = Fractor::Supervisor.new(
            worker_pools: [{
              worker_class: MemoryIntensiveWorker,
              num_workers: 4,
            }],
          )

          work_items = Array.new(100) do |i|
            Fractor::Work.new(value: i)
          end

          supervisor.add_work_items(work_items)
          supervisor.run

          GC.start
          after_memory = current_memory_mb
          after_memory - before_memory
          memory_samples << after_memory
        end

        first_half_avg = memory_samples[0..4].sum / 5.0
        second_half_avg = memory_samples[5..9].sum / 5.0
        growth = second_half_avg - first_half_avg

        if growth > 10

        elsif growth > 5

        end
      end
    end
  end
end

# Run benchmarks if executed directly
if __FILE__ == $PROGRAM_NAME
  Fractor::Benchmarks::MemoryBenchmark.new.run
end
