# frozen_string_literal: true

require_relative "../spec_helper"
require "benchmark/ips"

# Benchmark worker scaling performance
#
# Tests throughput with different numbers of workers (1, 2, 4, 8, 16)
#
# Usage:
#   ruby spec/benchmarks/worker_scaling_benchmark.rb

module Fractor
  module Benchmarks
    class WorkerScalingBenchmark
      # CPU-bound worker for scaling tests
      class ComputeWorker < Fractor::Worker
        def process(work)
          # Simulate CPU-intensive work
          n = work.input[:n] || 100
          result = (1..n).reduce(0) { |sum, i| sum + Math.sqrt(i) }
          Fractor::WorkResult.new(result: result, work: work)
        end
      end

      # I/O-bound worker for scaling tests
      class IOWorker < Fractor::Worker
        def process(work)
          # Simulate I/O wait
          sleep 0.001
          result = work.input[:data]
          Fractor::WorkResult.new(result: result, work: work)
        end
      end

      WORKER_COUNTS = [1, 2, 4, 8, 16].freeze
      WORK_COUNT = 1000

      def run
        puts "=" * 80
        puts "Worker Scaling Benchmarks"
        puts "=" * 80
        puts

        benchmark_cpu_bound_scaling
        benchmark_io_bound_scaling
        benchmark_mixed_workload
      end

      private

      def benchmark_cpu_bound_scaling
        puts "CPU-Bound Work Scaling (#{WORK_COUNT} items)"
        puts "-" * 80

        Benchmark.ips do |x|
          x.config(time: 10, warmup: 2)

          WORKER_COUNTS.each do |worker_count|
            x.report("#{worker_count} workers") do
              supervisor = Fractor::Supervisor.new(
                worker_pools: [{
                  worker_class: ComputeWorker,
                  num_workers: worker_count,
                }],
              )

              work_items = Array.new(WORK_COUNT) do |_i|
                Fractor::Work.new(n: 100)
              end

              supervisor.add_work_items(work_items)
              supervisor.run
            end
          end

          x.compare!
        end
        puts
      end

      def benchmark_io_bound_scaling
        puts "I/O-Bound Work Scaling (#{WORK_COUNT} items)"
        puts "-" * 80

        Benchmark.ips do |x|
          x.config(time: 10, warmup: 2)

          WORKER_COUNTS.each do |worker_count|
            x.report("#{worker_count} workers") do
              supervisor = Fractor::Supervisor.new(
                worker_pools: [{
                  worker_class: IOWorker,
                  num_workers: worker_count,
                }],
              )

              work_items = Array.new(WORK_COUNT) do |i|
                Fractor::Work.new(data: "item_#{i}")
              end

              supervisor.add_work_items(work_items)
              supervisor.run
            end
          end

          x.compare!
        end
        puts
      end

      def benchmark_mixed_workload
        puts "Mixed Workload (50% CPU, 50% I/O, #{WORK_COUNT} items)"
        puts "-" * 80

        Benchmark.ips do |x|
          x.config(time: 10, warmup: 2)

          WORKER_COUNTS.each do |worker_count|
            x.report("#{worker_count} workers") do
              supervisor = Fractor::Supervisor.new(
                worker_pools: [
                  {
                    worker_class: ComputeWorker,
                    num_workers: worker_count / 2,
                  },
                  {
                    worker_class: IOWorker,
                    num_workers: worker_count / 2,
                  },
                ],
              )

              work_items = Array.new(WORK_COUNT) do |i|
                if i.even?
                  Fractor::Work.new(n: 100)
                else
                  Fractor::Work.new(data: "item_#{i}")
                end
              end

              supervisor.add_work_items(work_items)
              supervisor.run
            end
          end

          x.compare!
        end
        puts
      end
    end
  end
end

# Run benchmarks if executed directly
if __FILE__ == $PROGRAM_NAME
  Fractor::Benchmarks::WorkerScalingBenchmark.new.run
end
