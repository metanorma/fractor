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
        puts "=" * 80
        puts "Memory Usage Benchmarks"
        puts "=" * 80
        puts

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
        puts "Baseline Memory Usage"
        puts "-" * 80

        GC.start
        initial_memory = current_memory_mb

        puts "Initial memory: #{initial_memory.round(2)} MB"
        puts
      end

      def benchmark_supervisor_memory
        puts "Supervisor Memory Usage (1000 items, 4 workers)"
        puts "-" * 80

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
        memory_used = after_memory - before_memory

        puts "Memory before: #{before_memory.round(2)} MB"
        puts "Memory after:  #{after_memory.round(2)} MB"
        puts "Memory used:   #{memory_used.round(2)} MB"
        puts
      end

      def benchmark_workflow_memory
        puts "Workflow Memory Usage (linear workflow, 1000 items)"
        puts "-" * 80

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
        memory_used = after_memory - before_memory

        puts "Memory before: #{before_memory.round(2)} MB"
        puts "Memory after:  #{after_memory.round(2)} MB"
        puts "Memory used:   #{memory_used.round(2)} MB"
        puts
      end

      def benchmark_memory_leak_detection
        puts "Memory Leak Detection (10 iterations)"
        puts "-" * 80

        memory_samples = []

        10.times do |iteration|
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
          memory_used = after_memory - before_memory
          memory_samples << after_memory

          puts "Iteration #{iteration + 1}: " \
               "#{before_memory.round(2)} MB -> " \
               "#{after_memory.round(2)} MB " \
               "(+#{memory_used.round(2)} MB)"
        end

        puts
        puts "Memory trend analysis:"
        first_half_avg = memory_samples[0..4].sum / 5.0
        second_half_avg = memory_samples[5..9].sum / 5.0
        growth = second_half_avg - first_half_avg

        puts "First 5 iterations avg:  #{first_half_avg.round(2)} MB"
        puts "Last 5 iterations avg:   #{second_half_avg.round(2)} MB"
        puts "Memory growth:           #{growth.round(2)} MB"

        if growth > 10
          puts "WARNING: Possible memory leak detected!"
        elsif growth > 5
          puts "NOTICE: Moderate memory growth observed"
        else
          puts "OK: Memory usage is stable"
        end
        puts
      end
    end
  end
end

# Run benchmarks if executed directly
if __FILE__ == $PROGRAM_NAME
  Fractor::Benchmarks::MemoryBenchmark.new.run
end
