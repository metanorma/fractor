#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "../../lib/fractor"
require "json"
require "time"

# Event data structure
class Event < Fractor::Work
  def initialize(type:, data:, timestamp: Time.now)
    super({
      type: type,
      data: data,
      timestamp: timestamp
    })
  end

  def type
    input[:type]
  end

  def data
    input[:data]
  end

  def timestamp
    input[:timestamp]
  end

  def to_s
    "Event(#{type}, #{timestamp.iso8601})"
  end
end

# Worker for processing events
class EventProcessorWorker < Fractor::Worker
  def process(work)
    return nil unless work.is_a?(Event)

    # Process event
    {
      type: work.type,
      data: work.data,
      timestamp: work.timestamp,
      processed_at: Time.now,
      processing_time: (Time.now - work.timestamp) * 1000 # ms
    }
  end
end

# Real-time stream processor (simplified for testing)
class StreamProcessor
  attr_reader :processed_count, :error_count, :window_size, :metrics

  def initialize(window_size: 5, num_workers: 4)
    @window_size = window_size
    @num_workers = num_workers
    @processed_count = 0
    @error_count = 0
    @events_in_window = []
    @metrics = {
      total_events: 0,
      events_per_second: 0.0,
      average_processing_time: 0.0,
      current_window_count: 0
    }
    @start_time = Time.now
    @mutex = Mutex.new
    @supervisor = nil
    @running = false
  end

  def start
    puts "Starting Stream Processor..."
    puts "Window size: #{@window_size} seconds"
    puts "Workers: #{@num_workers}"
    puts

    @supervisor = Fractor::Supervisor.new(
      worker_pools: [
        { worker_class: EventProcessorWorker, num_workers: @num_workers }
      ]
    )

    @running = true
    @start_time = Time.now

    self
  end

  def add_event(event)
    return unless @supervisor && @running

    @supervisor.add_work_item(event)

    @mutex.synchronize do
      @metrics[:total_events] += 1
    end
  end

  def process_events
    return unless @supervisor && @running

    @supervisor.run

    results_obj = @supervisor.results
    all_results = results_obj.results + results_obj.errors

    all_results.each do |work_result|
      result = work_result.respond_to?(:result) ? work_result.result : work_result

      next unless result.is_a?(Hash)

      process_result(result)
    end
  end

  def stop
    puts "\nStopping Stream Processor..."
    @running = false
    print_final_summary
  end

  private

  def process_result(result)
    @mutex.synchronize do
      @processed_count += 1

      # Add to current window
      @events_in_window << result

      # Remove events outside window
      cutoff_time = Time.now - @window_size
      @events_in_window.reject! do |r|
        r[:processed_at] < cutoff_time
      end

      # Update metrics
      @metrics[:current_window_count] = @events_in_window.size

      if @processed_count > 0
        elapsed = Time.now - @start_time
        @metrics[:events_per_second] = @processed_count / elapsed

        total_time = @events_in_window.sum { |r| r[:processing_time] }
        @metrics[:average_processing_time] =
          @events_in_window.empty? ? 0.0 : total_time / @events_in_window.size
      end
    end
  end

  def print_metrics
    @mutex.synchronize do
      print "\r"
      print "Events: #{@metrics[:total_events]} | "
      print "Processed: #{@processed_count} | "
      print "Rate: #{@metrics[:events_per_second].round(2)} e/s | "
      print "Window: #{@metrics[:current_window_count]} | "
      print "Avg Time: #{@metrics[:average_processing_time].round(2)} ms"
      $stdout.flush
    end
  end

  def print_final_summary
    puts "\n"
    puts "=" * 60
    puts "FINAL SUMMARY"
    puts "=" * 60
    puts format("Total Events: %d", @metrics[:total_events])
    puts format("Processed: %d", @processed_count)
    puts format("Errors: %d", @error_count)
    elapsed = Time.now - @start_time
    puts format("Duration: %.2f seconds", elapsed)
    rate = @processed_count > 0 ? @processed_count / elapsed : 0.0
    puts format("Average Rate: %.2f events/second", rate)
    puts "=" * 60
  end
end

# Event generator for testing
class EventGenerator
  def self.generate_stream(processor, duration: 10, rate: 10)
    puts "Generating event stream for #{duration} seconds at #{rate} events/second..."

    start_time = Time.now
    event_count = 0

    while (Time.now - start_time) < duration
      event = Event.new(
        type: [:click, :view, :purchase, :signup].sample,
        data: {
          user_id: rand(1..1000),
          value: rand(1.0..100.0).round(2)
        }
      )

      processor.add_event(event)
      event_count += 1

      # Control rate
      sleep(1.0 / rate)
    end

    puts "\nGenerated #{event_count} events"
  end
end

# Run example if executed directly
if __FILE__ == $PROGRAM_NAME
  require "optparse"

  options = {
    workers: 4,
    window_size: 5,
    duration: 30,
    rate: 10
  }

  OptionParser.new do |opts|
    opts.banner = "Usage: stream_processor.rb [options]"

    opts.on("-w", "--workers NUM", Integer, "Number of workers (default: 4)") do |n|
      options[:workers] = n
    end

    opts.on("--window SIZE", Integer, "Window size in seconds (default: 5)") do |s|
      options[:window_size] = s
    end

    opts.on("-d", "--duration SECONDS", Integer, "Test duration (default: 30)") do |d|
      options[:duration] = d
    end

    opts.on("-r", "--rate NUM", Integer, "Events per second (default: 10)") do |r|
      options[:rate] = r
    end

    opts.on("-h", "--help", "Show this message") do
      puts opts
      exit
    end
  end.parse!

  # Create processor
  processor = StreamProcessor.new(
    window_size: options[:window_size],
    num_workers: options[:workers]
  )

  processor.start

  # Handle graceful shutdown
  trap("INT") do
    processor.stop
    exit
  end

  # Generate test events in background
  generator_thread = Thread.new do
    EventGenerator.generate_stream(
      processor,
      duration: options[:duration],
      rate: options[:rate]
    )
  end

  # Process events periodically
  metrics_thread = Thread.new do
    while processor.instance_variable_get(:@running)
      sleep(1)
      processor.send(:print_metrics)
    end
  end

  # Wait for generation to complete
  generator_thread.join

  # Process remaining events
  processor.process_events

  metrics_thread.kill
  processor.stop
end