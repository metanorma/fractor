# frozen_string_literal: true

require_relative '../lib/fractor'

module ProducerSubscriber
  # Define work types
  class InitialWork < Fractor::Work
    attr_reader :data, :depth

    def initialize(data, depth = 0)
      super(work_type: :initial_processing)
      @data = data
      @depth = depth
      @retry_count = 0
      @max_retries = 2
    end

    def should_retry?
      @retry_count < @max_retries
    end

    def failed
      @retry_count += 1
    end
  end

  class SubWork < Fractor::Work
    attr_reader :data, :parent_id, :depth

    def initialize(data, parent_id, depth)
      super(work_type: :sub_processing)
      @data = data
      @parent_id = parent_id
      @depth = depth
      @retry_count = 0
      @max_retries = 2
    end

    def should_retry?
      @retry_count < @max_retries
    end

    def failed
      @retry_count += 1
    end
  end

  # Define work results
  class InitialWorkResult < Fractor::WorkResult
    attr_reader :processed_data, :sub_works

    def initialize(work, processed_data, sub_works = [])
      super(work)
      @processed_data = processed_data
      @sub_works = sub_works
    end
  end

  class SubWorkResult < Fractor::WorkResult
    attr_reader :processed_data, :parent_id

    def initialize(work, processed_data)
      super(work)
      @processed_data = processed_data
      @parent_id = work.parent_id
    end
  end

  # Define worker that can handle both types of work
  class MultiWorker < Fractor::Worker
    work_type_accepted [:initial_processing, :sub_processing]

    def process_work(work)
      case work.work_type
      when :initial_processing
        process_initial_work(work)
      when :sub_processing
        process_sub_work(work)
      end
    end

    private

    def process_initial_work(work)
      # Simulate processing time
      sleep(rand(0.01..0.05))

      # Process the data
      processed_data = "Processed: #{work.data}"

      # Create sub-works if we're not too deep
      sub_works = []
      if work.depth < 2  # Limit recursion depth
        # Split the work into smaller chunks
        3.times do |i|
          sub_data = "#{work.data}-#{i}"
          sub_works << SubWork.new(sub_data, work.object_id, work.depth + 1)
        end
      end

      # Return result with sub-works
      InitialWorkResult.new(work, processed_data, sub_works)
    end

    def process_sub_work(work)
      # Simulate processing time
      sleep(rand(0.01..0.03))

      # Process the data
      processed_data = "Sub-processed: #{work.data} (depth: #{work.depth})"

      # Create more sub-works if we're not too deep
      sub_works = []
      if work.depth < 3  # Limit recursion depth
        # Create fewer sub-works as we go deeper
        (4 - work.depth).times do |i|
          sub_data = "#{work.data}-#{i}"
          sub_works << SubWork.new(sub_data, work.parent_id, work.depth + 1)
        end
      end

      # Return result with any new sub-works
      result = SubWorkResult.new(work, processed_data)
      [result, sub_works]
    end
  end

  # Define result assembler
  class TreeResultAssembler < Fractor::ResultAssembler
    def initialize
      super()
      @result_tree = {}
      @pending_work_count = 0
    end

    def track_new_work(count = 1)
      @pending_work_count += count
    end

    def work_completed
      @pending_work_count -= 1
    end

    def add_result(result)
      super(result)
      work_completed

      case result
      when InitialWorkResult
        @result_tree[result.work.object_id] = {
          data: result.processed_data,
          children: []
        }
      when SubWorkResult
        parent = @result_tree[result.parent_id]
        if parent
          parent[:children] << result.processed_data
        end
      end
    end

    def all_work_complete?
      @pending_work_count <= 0
    end

    def finalize
      # Build a formatted tree representation
      format_tree
    end

    private

    def format_tree
      result = []
      @result_tree.each do |id, node|
        result << "Root: #{node[:data]}"
        node[:children].each_with_index do |child, index|
          result << "  ├─ Child #{index + 1}: #{child}"
        end
        result << ""
      end
      result.join("\n")
    end
  end

  # Define supervisor
  class TreeSupervisor < Fractor::Supervisor
    def initialize(initial_data, worker_count = 4)
      super()
      @initial_data = initial_data
      @worker_count = worker_count
      @assembler = TreeResultAssembler.new

      # Create a queue that can handle both work types
      work_queue = Fractor::Queue.new(work_types: [:initial_processing, :sub_processing])
      add_queue(work_queue)

      # Create a worker pool
      worker_pool = Fractor::Pool.new(size: @worker_count)
      @worker_count.times do
        worker_pool.add_worker(MultiWorker.new)
      end
      add_pool(worker_pool)

      # Create initial work
      initial_data.each do |data|
        work = InitialWork.new(data)
        @queues.first.push(work)
        @assembler.track_new_work
      end
    end

    def process_results
      until @assembler.all_work_complete? && @queues.all?(&:empty?)
        result_data = next_result
        next if result_data.nil?

        type, *data = result_data

        case type
        when :result
          result = data.first

          if result.is_a?(Array)
            # Handle the case where we get a result and sub-works
            sub_result, sub_works = result
            @assembler.add_result(sub_result)

            # Add new sub-works to the queue
            if sub_works && !sub_works.empty?
              @assembler.track_new_work(sub_works.size)
              sub_works.each do |work|
                @queues.first.push(work)
              end
            end
          else
            # Handle regular result
            @assembler.add_result(result)

            # If this result generated sub-works, add them to the queue
            if result.respond_to?(:sub_works) && !result.sub_works.empty?
              @assembler.track_new_work(result.sub_works.size)
              result.sub_works.each do |work|
                @queues.first.push(work)
              end
            end
          end

        when :error
          work, error = data
          @assembler.add_failed_work(work, error)
          @assembler.work_completed
        end

        # Small sleep to prevent CPU spinning
        sleep 0.001
      end

      # Return the final assembled result
      @assembler.finalize
    end
  end
end

# Example usage: Document processing system
if __FILE__ == $PROGRAM_NAME
  puts "Starting producer-subscriber example: Document Processing System"
  puts "This example simulates a document processing system where:"
  puts "1. Initial documents are broken down into sections"
  puts "2. Sections are further broken down into paragraphs"
  puts "3. Paragraphs are processed individually"
  puts "4. Results are assembled into a hierarchical structure"
  puts

  # Sample documents to process
  documents = [
    "Annual Report 2025",
    "Technical Documentation",
    "Research Paper"
  ]

  worker_count = 4
  puts "Using #{worker_count} workers to process #{documents.size} documents"
  puts

  start_time = Time.now
  supervisor = ProducerSubscriber::TreeSupervisor.new(documents, worker_count)
  result = supervisor.start
  end_time = Time.now

  puts "Processing Results:"
  puts "==================="
  puts result
  puts
  puts "Processing completed in #{end_time - start_time} seconds"

  supervisor.shutdown
end
