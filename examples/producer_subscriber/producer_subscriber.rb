# frozen_string_literal: true

require_relative "../../lib/fractor"

module ProducerSubscriber
  # Initial work that will generate sub-works
  class InitialWork < Fractor::Work
    def initialize(data, depth = 0)
      super({
        data: data,
        depth: depth,
      })
    end

    def data
      input[:data]
    end

    def depth
      input[:depth]
    end

    def to_s
      "InitialWork: data=#{data}, depth=#{depth}"
    end
  end

  # Work that is generated from initial work
  class SubWork < Fractor::Work
    def initialize(data, parent_id = nil, depth = 0)
      super({
        data: data,
        parent_id: parent_id,
        depth: depth,
      })
    end

    def data
      input[:data]
    end

    def parent_id
      input[:parent_id]
    end

    def depth
      input[:depth]
    end

    def to_s
      "SubWork: data=#{data}, parent_id=#{parent_id}, depth=#{depth}"
    end
  end

  # Worker that processes both types of work
  class MultiWorker < Fractor::Worker
    def process(work)
      # Handle different work types based on class
      if work.is_a?(InitialWork)
        process_initial_work(work)
      elsif work.is_a?(SubWork)
        process_sub_work(work)
      else
        Fractor::WorkResult.new(
          error: "Unknown work type: #{work.class}",
          work: work,
        )
      end
    end

    private

    def process_initial_work(work)
      # Simulate processing time
      sleep(rand(0.01..0.05))

      # Process the data
      processed_data = "Processed: #{work}"

      # Return the result with metadata about sub-works
      result = {
        processed_data: processed_data,
        sub_works: [], # Will be populated by the supervisor
      }

      # Return a successful result
      Fractor::WorkResult.new(
        result: result,
        work: work,
      )
    end

    def process_sub_work(work)
      # Simulate processing time
      sleep(rand(0.01..0.03))

      # Process the data
      processed_data = "Sub-processed: #{work.data} (depth: #{work.depth})"

      # Return a successful result
      Fractor::WorkResult.new(
        result: {
          processed_data: processed_data,
          parent_id: work.parent_id,
        },
        work: work,
      )
    end
  end

  # Manager for the document processing system
  class DocumentProcessor
    attr_reader :documents, :worker_count, :result_tree

    def initialize(documents, worker_count = 4)
      @documents = documents
      @worker_count = worker_count
      @result_tree = {}
    end

    def process
      # Create the supervisor
      supervisor = Fractor::Supervisor.new(
        worker_pools: [
          { worker_class: MultiWorker, num_workers: @worker_count },
        ],
      )

      # Create and add initial work items
      initial_work_items = documents.map { |doc| InitialWork.new(doc, 0) }
      supervisor.add_work_items(initial_work_items)

      # Run the initial processing
      supervisor.run

      # Analyze results and create sub-works
      sub_works = create_sub_works(supervisor.results)

      # If we have sub-works, process them too
      if sub_works.empty?
        # Just build the result tree with the initial results
        build_result_tree(supervisor.results, nil)
      else
        # Create a new supervisor for sub-works
        sub_supervisor = Fractor::Supervisor.new(
          worker_pools: [
            { worker_class: MultiWorker, num_workers: @worker_count },
          ],
        )

        # Create and add the sub-work items
        sub_work_items = sub_works.map do |sw|
          SubWork.new(sw[:data], sw[:parent_id], sw[:depth])
        end
        sub_supervisor.add_work_items(sub_work_items)
        sub_supervisor.run

        # Build the final result tree
        build_result_tree(supervisor.results, sub_supervisor.results)
      end

      # Return a formatted representation of the tree
      format_tree
    end

    private

    def create_sub_works(results_aggregator)
      sub_works = []

      # Go through the successful results
      results_aggregator.results.each do |result|
        work = result.work

        # Only create sub-works if depth is less than 2
        next unless work.depth < 2

        # Create 3 sub-works for each initial work
        3.times do |i|
          sub_data = "#{work.data}-#{i}"
          sub_works << {
            data: sub_data,
            parent_id: work.object_id,
            depth: work.depth + 1,
          }
        end

        # Store the sub-work IDs in the result for reference
        result.result[:sub_works] = sub_works.last(3).map do |sw|
          sw[:parent_id]
        end
      end

      sub_works
    end

    def build_result_tree(initial_results, sub_results)
      # Process initial results to build the base tree
      initial_results.results.each do |result|
        @result_tree[result.work.object_id] = {
          data: result.result[:processed_data],
          children: [],
        }
      end

      # Process sub-results if any
      return unless sub_results

      sub_results.results.each do |result|
        parent_id = result.result[:parent_id]
        @result_tree[parent_id][:children] << result.result[:processed_data] if @result_tree[parent_id]
      end
    end

    def format_tree
      result = []
      @result_tree.each_value do |node|
        result << "Root: #{node[:data]}"
        node[:children].each_with_index do |child, index|
          result << "  ├─ Child #{index + 1}: #{child}"
        end
        result << ""
      end
      result.join("\n")
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
    "Research Paper",
  ]

  worker_count = 4
  puts "Using #{worker_count} workers to process #{documents.size} documents"
  puts

  start_time = Time.now
  processor = ProducerSubscriber::DocumentProcessor.new(documents, worker_count)
  result = processor.process
  end_time = Time.now

  puts "Processing Results:"
  puts "==================="
  puts result
  puts
  puts "Processing completed in #{end_time - start_time} seconds"
end
