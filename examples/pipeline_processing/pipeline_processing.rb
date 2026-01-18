# frozen_string_literal: true

require_relative "../../lib/fractor"

module PipelineProcessing
  # Work that carries both the data and stage information
  class MediaWork < Fractor::Work
    def initialize(data, stage = :resize, metadata = {})
      super({
        data: data,
        stage: stage,
        metadata: metadata,
      })
    end

    def data
      input[:data]
    end

    def stage
      input[:stage]
    end

    def metadata
      input[:metadata]
    end

    def to_s
      "MediaWork: stage=#{stage}, metadata=#{metadata}, data_size=#{begin
        data.bytesize
      rescue StandardError
        'unknown'
      end}"
    end
  end

  # Worker for all pipeline stages
  class PipelineWorker < Fractor::Worker
    def process(work)
      # Process based on the stage
      result = case work.stage
               when :resize then process_resize(work)
               when :filter then process_filter(work)
               when :compress then process_compress(work)
               when :tag then process_tag(work)
               else
                 return Fractor::WorkResult.new(
                   error: "Unknown stage: #{work.stage}",
                   work: work,
                 )
               end

      # Determine the next stage
      stages = %i[resize filter compress tag]
      current_index = stages.index(work.stage)
      next_stage = current_index < stages.size - 1 ? stages[current_index + 1] : nil

      # Update metadata with processing information
      updated_metadata = work.metadata.merge(
        "#{work.stage}_completed".to_sym => true,
        "#{work.stage}_time".to_sym => Time.now.to_s,
      )

      # Return the result with next stage information
      Fractor::WorkResult.new(
        result: {
          processed_data: result,
          current_stage: work.stage,
          next_stage: next_stage,
          metadata: updated_metadata,
        },
        work: work,
      )
    end

    private

    def process_resize(work)
      sleep(rand(0.01..0.05)) # Simulate processing time
      "Resized image: #{work.data} (#{rand(800..1200)}x#{rand(600..900)})"
    end

    def process_filter(work)
      sleep(rand(0.01..0.05)) # Simulate processing time
      filters = %w[sepia grayscale vibrance contrast]
      "Applied #{filters.sample} filter to: #{work.data}"
    end

    def process_compress(work)
      sleep(rand(0.01..0.05)) # Simulate processing time
      "Compressed image: #{work.data} (reduced by #{rand(30..70)}%)"
    end

    def process_tag(work)
      sleep(rand(0.01..0.05)) # Simulate processing time
      tags = %w[landscape portrait nature urban abstract]
      selected_tags = tags.sample(rand(1..3))
      "Tagged image: #{work.data} (tags: #{selected_tags.join(', ')})"
    end
  end

  # Controller class that manages the pipeline flow
  class MediaPipeline
    attr_reader :results

    def initialize(worker_count = 4)
      @supervisor = Fractor::Supervisor.new(
        worker_pools: [
          { worker_class: PipelineWorker, num_workers: worker_count },
        ],
      )

      # Register callback to handle pipeline stage transitions
      @supervisor.results.on_new_result do |result|
        next_stage = result.result[:next_stage]

        if next_stage
          # Create new work for the next stage
          new_work = MediaWork.new(
            result.result[:processed_data],
            next_stage,
            result.result[:metadata],
          )
          @supervisor.add_work_item(new_work)
        end
      end

      @results = {
        completed: [],
        in_progress: [],
      }
    end

    def process_images(images)
      # Create initial work items for the first stage (resize)
      initial_work_items = images.map do |image|
        MediaWork.new(
          image,
          :resize,
          { original_filename: image, started_at: Time.now.to_s },
        )
      end

      # Add the work items and run the pipeline
      @supervisor.add_work_items(initial_work_items)
      @supervisor.run

      # Analyze results - collect completed ones (those that reached the final stage)
      @supervisor.results.results.each do |result|
        if result.result[:next_stage].nil?
          @results[:completed] << result.result
        else
          @results[:in_progress] << result.result
        end
      end

      # Return summary
      {
        total_images: images.size,
        completed: @results[:completed].size,
        in_progress: @results[:in_progress].size,
        results: @results[:completed],
      }
    end
  end
end

# Example usage
if __FILE__ == $PROGRAM_NAME
  puts "Starting Pipeline Processing Example"
  puts "====================================="
  puts "This example demonstrates a media processing pipeline with multiple stages:"
  puts "1. Resize - Adjusts image dimensions"
  puts "2. Filter - Applies visual filters"
  puts "3. Compress - Optimizes file size"
  puts "4. Tag - Analyzes and adds metadata tags"
  puts

  # Simulate some images to process
  images = [
    "sunset.jpg",
    "mountains.png",
    "beach.jpg",
    "city_skyline.jpg",
    "forest.png",
  ]

  worker_count = 4
  puts "Processing #{images.size} images with #{worker_count} workers..."
  puts

  start_time = Time.now
  pipeline = PipelineProcessing::MediaPipeline.new(worker_count)
  result = pipeline.process_images(images)
  end_time = Time.now

  puts "Pipeline Results:"
  puts "----------------"
  puts "Total images: #{result[:total_images]}"
  puts "Completed: #{result[:completed]}"
  puts "In progress: #{result[:in_progress]}"
  puts
  puts "Processed Images:"
  result[:results].each_with_index do |image_result, index|
    puts "Image #{index + 1}: #{image_result[:processed_data]}"
    puts "  Processing path:"
    image_result[:metadata].each do |key, value|
      next unless key.to_s.end_with?("_completed", "_time")

      puts "    #{key}: #{value}"
    end
    puts
  end

  puts "Processing completed in #{end_time - start_time} seconds"
end
