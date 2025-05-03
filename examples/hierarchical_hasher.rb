# frozen_string_literal: true

require 'digest'
require_relative '../lib/fractor'

module HierarchicalHasher
  class ChunkWork < Fractor::Work
    attr_reader :start, :length, :data

    def initialize(start, length, data)
      super(work_type: :chunk_hash)
      @start = start
      @length = length
      @data = data
      @retry_count = 0
      @max_retries = 3
    end

    def should_retry?
      @retry_count < @max_retries
    end

    def failed
      @retry_count += 1
    end
  end

  class ChunkResult < Fractor::WorkResult
    attr_reader :start, :length, :hash_result

    def initialize(work, hash_result)
      super(work)
      @start = work.start
      @length = work.length
      @hash_result = hash_result
    end
  end

  class HashWorker < Fractor::Worker
    work_type_accepted :chunk_hash

    def process_work(work)
      # Simulate some processing time
      sleep(rand(0.01..0.05))

      # Calculate SHA-3 hash for the chunk
      hash = Digest::SHA3.hexdigest(work.data)

      # Return the result
      ChunkResult.new(work, hash)
    end
  end

  class HashResultAssembler < Fractor::ResultAssembler
    def finalize
      return nil if @results.empty?

      # Sort results by start position
      sorted_results = @results.sort_by { |result| result.start }

      # Concatenate all hashes with newlines
      combined_hash_string = sorted_results.map(&:hash_result).join("\n")

      # Calculate final SHA-3 hash
      Digest::SHA3.hexdigest(combined_hash_string)
    end
  end

  class HashSupervisor < Fractor::Supervisor
    def initialize(file_path, chunk_size = 1024, worker_count = 4)
      super()
      @file_path = file_path
      @chunk_size = chunk_size
      @worker_count = worker_count
      @assembler = HashResultAssembler.new

      # Create a queue for chunk work
      chunk_queue = Fractor::Queue.new(work_types: [:chunk_hash])
      add_queue(chunk_queue)

      # Create a worker pool
      worker_pool = Fractor::Pool.new(size: @worker_count)
      @worker_count.times do
        worker_pool.add_worker(HashWorker.new)
      end
      add_pool(worker_pool)

      # Load the file and create work chunks
      load_file_chunks
    end

    def load_file_chunks
      File.open(@file_path, 'rb') do |file|
        start_pos = 0

        while chunk = file.read(@chunk_size)
          work = ChunkWork.new(start_pos, chunk.length, chunk)
          @queues.first.push(work)
          start_pos += chunk.length
        end
      end
    end

    def process_results
      until @queues.all?(&:empty?) && @pools.all?(&:all_idle?)
        result_data = next_result
        next if result_data.nil?

        type, *data = result_data

        case type
        when :result
          result = data.first
          @assembler.add_result(result)
        when :error
          work, error = data
          @assembler.add_failed_work(work, error)
        end

        # Small sleep to prevent CPU spinning
        sleep 0.001
      end

      # Return the final hash
      @assembler.finalize
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
  supervisor = HierarchicalHasher::HashSupervisor.new(file_path, 1024, worker_count)
  final_hash = supervisor.start
  end_time = Time.now

  puts "Final SHA-3 hash: #{final_hash}"
  puts "Processing completed in #{end_time - start_time} seconds"

  supervisor.shutdown
end
