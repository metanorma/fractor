# frozen_string_literal: true

require_relative "../spec_helper"
require "benchmark/ips"

# Benchmark queue operations
#
# Tests WorkQueue performance for enqueue, dequeue, and concurrent access
#
# Usage:
#   ruby spec/benchmarks/queue_benchmark.rb

module Fractor
  module Benchmarks
    class QueueBenchmark
      QUEUE_SIZES = [100, 1000, 10000].freeze

      def run
        puts "=" * 80
        puts "Queue Operations Benchmarks"
        puts "=" * 80
        puts

        benchmark_enqueue
        benchmark_dequeue
        benchmark_concurrent_access
        benchmark_queue_iteration
      end

      private

      def benchmark_enqueue
        puts "Enqueue Operations"
        puts "-" * 80

        Benchmark.ips do |x|
          x.config(time: 5, warmup: 2)

          QUEUE_SIZES.each do |size|
            x.report("enqueue #{size} items") do
              queue = Fractor::WorkQueue.new
              size.times do |i|
                queue << Fractor::Work.new(value: i)
              end
            end
          end

          x.compare!
        end
        puts
      end

      def benchmark_dequeue
        puts "Dequeue Operations"
        puts "-" * 80

        Benchmark.ips do |x|
          x.config(time: 5, warmup: 2)

          QUEUE_SIZES.each do |size|
            x.report("dequeue #{size} items") do
              queue = Fractor::WorkQueue.new
              size.times { |i| queue << Fractor::Work.new(value: i) }

              size.times { queue.pop }
            end
          end

          x.compare!
        end
        puts
      end

      def benchmark_concurrent_access
        puts "Concurrent Queue Access (4 threads)"
        puts "-" * 80

        Benchmark.ips do |x|
          x.config(time: 5, warmup: 2)

          [100, 1000].each do |size|
            x.report("concurrent #{size} items") do
              queue = Fractor::WorkQueue.new

              # Producer threads
              producers = Array.new(2) do
                Thread.new do
                  (size / 2).times do |i|
                    queue << Fractor::Work.new(value: i)
                  end
                end
              end

              # Consumer threads
              consumers = Array.new(2) do
                Thread.new do
                  (size / 2).times do
                    queue.pop
                  end
                end
              end

              producers.each(&:join)
              consumers.each(&:join)
            end
          end

          x.compare!
        end
        puts
      end

      def benchmark_queue_iteration
        puts "Queue Iteration and Inspection"
        puts "-" * 80

        Benchmark.ips do |x|
          x.config(time: 5, warmup: 2)

          [100, 1000].each do |size|
            queue = Fractor::WorkQueue.new
            size.times { |i| queue << Fractor::Work.new(value: i) }

            x.report("size check (#{size} items)") do
              queue.size
            end

            x.report("empty check (#{size} items)") do
              queue.empty?
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
  Fractor::Benchmarks::QueueBenchmark.new.run
end
