#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "../../lib/fractor"
require "fileutils"
require "json"

module ImageProcessor
  # ImageWork encapsulates an image file and the processing operations to perform
  class ImageWork < Fractor::Work
  def initialize(input_path, output_path, operations = {})
    super({
      input_path: input_path,
      output_path: output_path,
      operations: operations
    })
  end

  def input_path
    input[:input_path]
  end

  def output_path
    input[:output_path]
  end

  def operations
    input[:operations]
  end

  def to_s
    "ImageWork(#{File.basename(input_path)} -> #{operations.keys.join(", ")})"
  end
end

# ImageProcessorWorker performs image processing operations
  class ImageProcessorWorker < Fractor::Worker
  def process(work)
    unless work.is_a?(ImageWork)
      raise ArgumentError, "Expected ImageWork, got #{work.class}"
    end

    # Simulate image processing without requiring actual image libraries
    # In real implementation, would use mini_magick or similar
    process_image(work)

    {
      input: work.input_path,
      output: work.output_path,
      operations: work.operations,
      status: "success",
      file_size: simulate_file_size(work),
      processing_time: rand(0.1..0.5)
    }
  rescue ArgumentError => e
    # Re-raise ArgumentError for invalid work type
    raise e
  rescue StandardError => e
    {
      input: work.input_path,
      output: work.output_path,
      status: "error",
      error: e.message
    }
  end

  private

  def process_image(work)
    # Validate input file exists (in real scenario)
    unless File.exist?(work.input_path)
      raise "Input file not found: #{work.input_path}"
    end

    # Create output directory if needed
    FileUtils.mkdir_p(File.dirname(work.output_path))

    # Simulate processing based on operations
    operations = work.operations

    # Simulate different processing times based on operations
    sleep_time = 0.05 # Base time

    if operations[:resize]
      sleep_time += 0.02
      validate_resize_params(operations[:resize])
    end

    if operations[:convert]
      sleep_time += 0.01
      validate_format(operations[:convert])
    end

    if operations[:filter]
      sleep_time += 0.03
      validate_filter(operations[:filter])
    end

    if operations[:brightness]
      sleep_time += 0.01
      validate_brightness(operations[:brightness])
    end

    # Simulate processing time
    sleep(sleep_time)

    # In real implementation, would process the actual image here
    # For simulation, copy the file or create a marker file
    create_processed_output(work)
  end

  def validate_resize_params(resize_params)
    width = resize_params[:width]
    height = resize_params[:height]

    if width && width <= 0
      raise "Invalid width: #{width}"
    end

    if height && height <= 0
      raise "Invalid height: #{height}"
    end
  end

  def validate_format(format)
    valid_formats = %w[jpg jpeg png gif bmp webp]
    unless valid_formats.include?(format.to_s.downcase)
      raise "Unsupported format: #{format}"
    end
  end

  def validate_filter(filter)
    valid_filters = %w[grayscale sepia blur sharpen]
    unless valid_filters.include?(filter.to_s.downcase)
      raise "Unknown filter: #{filter}"
    end
  end

  def validate_brightness(brightness)
    unless brightness.is_a?(Numeric) && brightness >= -100 && brightness <= 100
      raise "Brightness must be between -100 and 100"
    end
  end

  def simulate_file_size(work)
    # Simulate output file size based on operations
    base_size = 102400 # 100KB base

    if work.operations[:resize]
      width = work.operations[:resize][:width] || 1000
      height = work.operations[:resize][:height] || 1000
      base_size = (width * height * 3) / 10 # Rough estimate
    end

    if work.operations[:convert] == "jpg"
      base_size = (base_size * 0.6).to_i # JPEG compression
    end

    base_size
  end

  def create_processed_output(work)
    # In simulation mode, create a JSON file with processing metadata
    # In real mode, this would be the actual processed image
    output_dir = File.dirname(work.output_path)
    FileUtils.mkdir_p(output_dir)

    metadata = {
      original: work.input_path,
      operations: work.operations,
      processed_at: Time.now.iso8601
    }

    # Create a marker file to show processing occurred
    File.write("#{work.output_path}.json", JSON.pretty_generate(metadata))
  end
end

# ProgressTracker monitors and displays processing progress
  class ProgressTracker
  attr_reader :total, :completed, :errors

  def initialize(total)
    @total = total
    @completed = 0
    @errors = 0
    @start_time = Time.now
    @lock = Mutex.new
  end

  def increment_completed
    @lock.synchronize do
      @completed += 1
      print_progress
    end
  end

  def increment_errors
    @lock.synchronize do
      @errors += 1
      @completed += 1
      print_progress
    end
  end

  def percentage
    return 0 if total.zero?

    ((completed.to_f / total) * 100).round(2)
  end

  def elapsed_time
    Time.now - @start_time
  end

  def estimated_remaining
    return 0 if completed.zero?

    rate = elapsed_time / completed
    (total - completed) * rate
  end

  def print_progress
    print "\rProcessing: #{completed}/#{total} (#{percentage}%) | "
    print "Errors: #{errors} | "
    print "Elapsed: #{format_time(elapsed_time)} | "
    print "Est. remaining: #{format_time(estimated_remaining)}"
    $stdout.flush
  end

  def print_summary
    puts "\n\n=== Processing Complete ==="
    puts "Total: #{total}"
    puts "Successful: #{completed - errors}"
    puts "Errors: #{errors}"
    puts "Total time: #{format_time(elapsed_time)}"
    puts "Average time per image: #{format_time(elapsed_time / total)}"
  end

  private

  def format_time(seconds)
    if seconds < 60
      format("%.2fs", seconds)
    else
      minutes = (seconds / 60).to_i
      secs = (seconds % 60).to_i
      format("%dm %ds", minutes, secs)
    end
  end
end

# Main execution
if __FILE__ == $PROGRAM_NAME
  # Create sample test images if they don't exist
  test_images_dir = File.join(__dir__, "test_images")
  FileUtils.mkdir_p(test_images_dir)

  # Create dummy test image files for demonstration
  sample_images = []
  10.times do |i|
    img_path = File.join(test_images_dir, "sample_#{i + 1}.png")
    unless File.exist?(img_path)
      File.write(img_path, "FAKE_PNG_DATA_#{i}")
    end
    sample_images << img_path
  end

  puts "=== Image Batch Processor with Fractor ==="
  puts "Processing #{sample_images.size} images in parallel"
  puts

  # Create output directory
  output_dir = File.join(__dir__, "processed_images")
  FileUtils.mkdir_p(output_dir)

  # Define processing operations
  operations = {
    resize: { width: 800, height: 600 },
    filter: "grayscale",
    convert: "jpg"
  }

  # Create work items
  work_items = sample_images.map do |img_path|
    output_path = File.join(
      output_dir,
      File.basename(img_path, ".*") + "_processed.jpg"
    )
    ImageProcessor::ImageWork.new(img_path, output_path, operations)
  end

  # Initialize progress tracker
  tracker = ImageProcessor::ProgressTracker.new(work_items.size)

  # Process with Fractor
  start_time = Time.now

  supervisor = Fractor::Supervisor.new(
    worker_pools: [
      { worker_class: ImageProcessor::ImageProcessorWorker, num_workers: 4 }
    ]
  )

  # Submit all work
  supervisor.add_work_items(work_items)

  # Start processing
  supervisor.run

  # Collect results and update progress
  results = []
  all_results = supervisor.results.results + supervisor.results.errors

  all_results.each do |work_result|
    result = work_result.result || {
      status: "error",
      error: work_result.error&.message || "Unknown error"
    }
    results << result

    if result[:status] == "error"
      tracker.increment_errors
    else
      tracker.increment_completed
    end
  end

  # Print summary
  tracker.print_summary

  # Show sample results
  puts "\n=== Sample Results ==="
  results.first(3).each do |result|
    puts "\nInput: #{File.basename(result[:input])}"
    puts "Output: #{File.basename(result[:output])}"
    puts "Operations: #{result[:operations].inspect}"
    puts "Status: #{result[:status]}"
    if result[:status] == "success"
      puts "File size: #{result[:file_size]} bytes"
      puts "Processing time: #{format("%.3f", result[:processing_time])}s"
    else
      puts "Error: #{result[:error]}"
    end
  end

  puts "\nProcessed images saved to: #{output_dir}"
end
end