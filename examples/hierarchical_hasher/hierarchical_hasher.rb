# frozen_string_literal: true

require_relative "../../lib/fractor"
require "digest/sha2" # Using SHA2 which is more Ractor-compatible

module HierarchicalHasher
  # Define our Work class
  class ChunkWork < Fractor::Work
    attr_reader :start, :length

    def initialize(input)
      if input.is_a?(Hash) && input[:data] && input[:start] && input[:length]
        # When called by Supervisor with a hash of data
        super(input[:data])
        @start = input[:start]
        @length = input[:length]
      else
        # When directly calling with chunk data
        super(input)
        @start = 0
        @length = input.bytesize
      end
    end

    def to_s
      "ChunkWork: start=#{@start}, length=#{@length}, data_size=#{input.bytesize}"
    end
  end

  # Define our Worker class
  class HashWorker < Fractor::Worker
    def process(work)
      # Simulate some processing time
      sleep(rand(0.01..0.05))

      # Calculate SHA-256 hash for the chunk (using SHA2 which is Ractor-compatible)
      begin
        hash = Digest::SHA256.hexdigest(work.input)

        # Return successful result
        Fractor::WorkResult.new(
          result: {
            start: work.start,
            length: work.length,
            hash: hash
          },
          work: work
        )
      rescue StandardError => e
        # Return error result if something goes wrong
        Fractor::WorkResult.new(
          error: "Failed to hash chunk: #{e.message}",
          work: work
        )
      end
    end
  end

  class FileHasher
    attr_reader :file_path, :chunk_size, :final_hash

    def initialize(file_path, chunk_size = 1024, worker_count = 4)
      @file_path = file_path
      @chunk_size = chunk_size
      @worker_count = worker_count
      @final_hash = nil
    end

    def hash_file
      # Create the supervisor with our worker and work classes
      supervisor = Fractor::Supervisor.new(
        worker_class: HashWorker,
        work_class: ChunkWork,
        num_workers: @worker_count
      )

      # Load the file and create work chunks
      load_file_chunks(supervisor)

      # Run the processing
      supervisor.run

      # Process the results to get the final hash
      @final_hash = finalize_hash(supervisor.results)

      @final_hash
    end

    private

    def load_file_chunks(supervisor)
      work_items = []

      File.open(@file_path, "rb") do |file|
        start_pos = 0

        while (chunk = file.read(@chunk_size))
          work_items << {
            start: start_pos,
            length: chunk.length,
            data: chunk
          }
          start_pos += chunk.length
        end
      end

      supervisor.add_work(work_items)
    end

    def finalize_hash(results_aggregator)
      return nil if results_aggregator.results.empty?

      # Sort results by start position
      sorted_results = results_aggregator.results.sort_by { |result| result.result[:start] }

      # Concatenate all hashes with newlines
      combined_hash_string = sorted_results.map { |result| result.result[:hash] }.join("\n")

      # Calculate final SHA-256 hash (instead of SHA3)
      Digest::SHA256.hexdigest(combined_hash_string)
    end
  end
end

# Example usage
if __FILE__ == $PROGRAM_NAME
  if ARGV.empty?
    puts "Usage: ruby hierarchical_hasher.rb <file_path> [worker_count]"
    exit 1
  end

  file_path = ARGV[0]
  worker_count = (ARGV[1] || 4).to_i

  unless File.exist?(file_path)
    puts "Error: File '#{file_path}' not found"
    exit 1
  end

  puts "Starting hierarchical hasher with #{worker_count} workers..."
  puts "Processing file: #{file_path}"

  start_time = Time.now
  hasher = HierarchicalHasher::FileHasher.new(file_path, 1024, worker_count)
  final_hash = hasher.hash_file
  end_time = Time.now

  puts "Final SHA-256 hash: #{final_hash}"
  puts "Processing completed in #{end_time - start_time} seconds"
end
