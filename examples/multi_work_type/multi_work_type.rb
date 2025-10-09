# frozen_string_literal: true

require_relative "../../lib/fractor"

module MultiWorkType
  # First work type for text data
  class TextWork < Fractor::Work
    def initialize(data, format = :plain, options = {})
      super({ data: data, format: format, options: options })
    end

    def data
      input[:data]
    end

    def format
      input[:format]
    end

    def options
      input[:options]
    end

    def to_s
      "TextWork: format=#{format}, options=#{options}, data=#{data.to_s[0..30]}..."
    end
  end

  # Second work type for image data
  class ImageWork < Fractor::Work
    def initialize(data, dimensions = [0, 0], format = :png)
      super({ data: data, dimensions: dimensions, format: format })
    end

    def data
      input[:data]
    end

    def dimensions
      input[:dimensions]
    end

    def format
      input[:format]
    end

    def to_s
      "ImageWork: dimensions=#{dimensions.join('x')}, format=#{format}"
    end
  end

  # A single worker that can process both work types
  class MultiFormatWorker < Fractor::Worker
    def process(work)
      # Differentiate processing based on work class
      if work.is_a?(TextWork)
        process_text(work)
      elsif work.is_a?(ImageWork)
        process_image(work)
      else
        # Return error for unsupported work types
        error = TypeError.new("Unsupported work type: #{work.class}")
        Fractor::WorkResult.new(
          error: error,
          work: work,
        )
      end
    end

    private

    def process_text(work)
      # Process text based on format
      sleep(rand(0.01..0.05)) # Simulate processing time

      processed_text = case work.format
                       when :markdown then process_markdown(work.data,
                                                            work.options)
                       when :html then process_html(work.data, work.options)
                       when :json then process_json(work.data, work.options)
                       else work.data.upcase # Simple transformation for plain text
                       end

      Fractor::WorkResult.new(
        result: {
          work_type: :text,
          original_format: work.format,
          transformed_data: processed_text,
          metadata: {
            word_count: processed_text.split(/\s+/).size,
            char_count: processed_text.length,
          },
        },
        work: work,
      )
    end

    def process_image(work)
      # Simulate image processing operations
      sleep(rand(0.03..0.1)) # Simulate processing time

      # Creating a safe copy of the data to avoid memory issues
      # Avoid calling methods directly on the input that might cause memory issues
      input_size = work.data.is_a?(String) ? work.data.size : 0

      # In a real implementation, this would use image processing libraries
      simulated_result = {
        work_type: :image,
        dimensions: work.dimensions,
        format: work.format,
        applied_filters: %i[sharpen contrast],
        processing_metadata: {
          original_size: input_size,
          processed_size: (input_size * 0.8).to_i, # Simulate compression
        },
      }

      Fractor::WorkResult.new(
        result: simulated_result,
        work: work,
      )
    end

    # Format-specific processing methods
    def process_markdown(text, _options)
      # Simulate Markdown processing
      headers = text.scan(/^#+\s+(.+)$/).flatten
      links = text.scan(/\[(.+?)\]\((.+?)\)/)

      "Processed Markdown: #{text.length} chars, #{headers.size} headers, #{links.size} links\n" \
        "Headers: #{headers.join(', ')}\n" \
        "#{text.gsub(/^#+\s+(.+)$/, '💫 \1 💫')}"
    end

    def process_html(text, _options)
      # Simulate HTML processing
      tags = text.scan(/<(\w+)[^>]*>/).flatten

      "Processed HTML: #{text.length} chars, #{tags.size} tags\n" \
        "Tags: #{tags.uniq.join(', ')}\n" \
        "#{text.gsub(%r{<(\w+)[^>]*>(.+?)</\1>}, '✨\2✨')}"
    end

    def process_json(text, _options)
      # Simulate JSON processing

      data = text.nil? ? {} : eval(text) # WARNING: Using eval for demonstration only
      keys = data.keys

      "Processed JSON: #{keys.size} top-level keys\n" \
        "Keys: #{keys.join(', ')}\n" \
        "Pretty-printed: #{data}"
    rescue StandardError => e
      "Invalid JSON: #{e.message}"
    end
  end

  # Controller class for the example
  class ContentProcessor
    attr_reader :results

    def initialize(worker_count = 4)
      # Create supervisor with a MultiFormatWorker pool
      @supervisor = Fractor::Supervisor.new(
        worker_pools: [
          { worker_class: MultiFormatWorker, num_workers: worker_count },
        ],
      )

      @results = {
        text: [],
        image: [],
        errors: [],
      }
    end

    def process_mixed_content(text_items, image_items)
      # Create TextWork objects and add them to the supervisor
      text_works = text_items.map do |item|
        TextWork.new(item[:data], item[:format], item[:options] || {})
      end
      @supervisor.add_work_items(text_works)

      # Create ImageWork objects and add them to the supervisor
      image_works = image_items.map do |item|
        ImageWork.new(item[:data], item[:dimensions], item[:format] || :png)
      end
      @supervisor.add_work_items(image_works)

      # Process all work
      @supervisor.run

      # Separate results by work type
      classify_results(@supervisor.results)

      # Return the statistics
      {
        total_items: text_items.size + image_items.size,
        processed: {
          text: @results[:text].size,
          image: @results[:image].size,
        },
        errors: @results[:errors].size,
        results: @results,
      }
    end

    private

    def classify_results(results_aggregator)
      # Group results by work type
      results_aggregator.results.each do |result|
        if result.work.is_a?(TextWork)
          @results[:text] << result.result
        elsif result.work.is_a?(ImageWork)
          @results[:image] << result.result
        end
      end

      # Record errors
      results_aggregator.errors.each do |error_result|
        @results[:errors] << {
          error: error_result.error,
          work_type: error_result.work.class.name,
        }
      end

      puts "Processed #{@results[:text].size} text items and #{@results[:image].size} image items"
      puts "Encountered #{@results[:errors].size} errors"
    end
  end
end

# Example usage
if __FILE__ == $PROGRAM_NAME
  puts "Starting Multi-Work Type Processing Example"
  puts "=========================================="
  puts "This example demonstrates processing different types of work items:"
  puts "1. Text documents in various formats (plain, markdown, HTML, JSON)"
  puts "2. Image data with different formats and dimensions"
  puts "Both are processed by the same worker but with different strategies"
  puts

  # Sample text items
  text_items = [
    {
      data: "This is a plain text document. It has no special formatting.",
      format: :plain,
    },
    {
      data: "# Markdown Document\n\nThis is a **bold** statement. Here's a [link](https://example.com).",
      format: :markdown,
    },
    {
      data: "<html><body><h1>HTML Document</h1><p>This is a paragraph.</p></body></html>",
      format: :html,
    },
    {
      data: "{name: 'Product', price: 29.99, tags: ['electronics', 'gadget']}",
      format: :json,
      options: { pretty: true },
    },
  ]

  # Sample image items (simulated)
  image_items = [
    {
      data: "simulated_jpeg_data_1",
      dimensions: [800, 600],
      format: :jpeg,
    },
    {
      data: "simulated_png_data_1",
      dimensions: [1024, 768],
      format: :png,
    },
    {
      data: "simulated_gif_data_1",
      dimensions: [320, 240],
      format: :gif,
    },
  ]

  worker_count = 4
  puts "Processing with #{worker_count} workers..."
  puts

  start_time = Time.now
  processor = MultiWorkType::ContentProcessor.new(worker_count)
  result = processor.process_mixed_content(text_items, image_items)
  end_time = Time.now

  puts "Processing Results:"
  puts "-----------------"
  puts "Total items: #{result[:total_items]}"
  puts "Processed text items: #{result[:processed][:text]}"
  puts "Processed image items: #{result[:processed][:image]}"
  puts "Errors: #{result[:errors]}"
  puts

  puts "Text Processing Results:"
  result[:results][:text].each_with_index do |text_result, index|
    puts "Text Item #{index + 1} (#{text_result[:original_format]}):"
    puts "  #{text_result[:transformed_data].to_s.split("\n").first}"
    puts "  Word count: #{text_result[:metadata][:word_count]}"
    puts "  Character count: #{text_result[:metadata][:char_count]}"
    puts
  end

  puts "Image Processing Results:"
  result[:results][:image].each_with_index do |image_result, index|
    puts "Image Item #{index + 1} (#{image_result[:format]}):"
    puts "  Dimensions: #{image_result[:dimensions].join('x')}"
    puts "  Applied filters: #{image_result[:applied_filters].join(', ')}"
    puts "  Compression: #{(1 - image_result[:processing_metadata][:processed_size].to_f / image_result[:processing_metadata][:original_size]).round(2) * 100}%"
    puts
  end

  puts "Processing completed in #{end_time - start_time} seconds"
end
