# frozen_string_literal: true

require_relative "../../lib/fractor"

module SpecializedWorkers
  # First work type: Compute-intensive operations
  class ComputeWork < Fractor::Work
    attr_reader :work_type

    def initialize(data, operation = :default, parameters = {})
      super({
        data: data,
        operation: operation,
        parameters: parameters,
        work_type: :compute,  # Add work type identifier for Ractor compatibility
      })
    end

    def data
      input[:data]
    end

    def operation
      input[:operation]
    end

    def parameters
      input[:parameters]
    end

    def work_type
      input[:work_type]
    end

    def to_s
      "ComputeWork: operation=#{operation}, parameters=#{parameters}"
    end
  end

  # Second work type: Database operations
  class DatabaseWork < Fractor::Work
    attr_reader :work_type

    def initialize(data = "", query_type = :select, table = "unknown",
conditions = {})
      super({
        data: data,
        query_type: query_type,
        table: table,
        conditions: conditions,
        work_type: :database,  # Add work type identifier for Ractor compatibility
      })
    end

    def data
      input[:data]
    end

    def query_type
      input[:query_type]
    end

    def table
      input[:table]
    end

    def conditions
      input[:conditions]
    end

    def work_type
      input[:work_type]
    end

    def to_s
      "DatabaseWork: query_type=#{query_type}, table=#{table}, conditions=#{conditions}"
    end
  end

  # First worker type: Handles compute-intensive operations
  class ComputeWorker < Fractor::Worker
    def initialize(name: nil, **options)
      super
      # Setup resources needed for computation
      # Use Ractor.make_shareable to make the hash shareable across Ractors
      @compute_resources = Ractor.make_shareable({ memory: 1024, cpu_cores: 4 })
    end

    def process(work)
      # Only handle ComputeWork - check work_type for Ractor compatibility
      unless work.respond_to?(:work_type) && work.work_type == :compute
        return Fractor::WorkResult.new(
          error: "ComputeWorker can only process ComputeWork, got: #{work.class}",
          work: work,
        )
      end

      # Process based on the requested operation
      result = case work.operation
               when :matrix_multiply then matrix_multiply(work.data,
                                                          work.parameters)
               when :image_transform then image_transform(work.data,
                                                          work.parameters)
               when :path_finding then path_finding(work.data, work.parameters)
               else default_computation(work.data, work.parameters)
               end

      Fractor::WorkResult.new(
        result: {
          operation: work.operation,
          computation_result: result,
          resources_used: @compute_resources,
        },
        work: work,
      )
    end

    # Computation methods
    private

    def matrix_multiply(_data, params)
      # Simulate matrix multiplication
      sleep(rand(0.05..0.2))
      size = params[:size] || [3, 3]
      "Matrix multiplication result: #{size[0]}x#{size[1]} matrix, determinant=#{rand(1..100)}"
    end

    def image_transform(_data, params)
      # Simulate image transformation
      sleep(rand(0.1..0.3))
      transforms = params[:transforms] || %i[rotate scale]
      "Image transformation applied: #{transforms.join(', ')} with parameters #{params}"
    end

    def path_finding(_data, params)
      # Simulate path finding algorithm
      sleep(rand(0.2..0.5))
      algorithm = params[:algorithm] || :a_star
      nodes = params[:nodes] || 10
      "Path found using #{algorithm}: #{rand(1..nodes)} steps, cost=#{rand(10..100)}"
    end

    def default_computation(data, _params)
      # Default computation
      sleep(rand(0.01..0.1))
      "Default computation result for input: #{data}"
    end
  end

  # Second worker type: Handles database operations
  class DatabaseWorker < Fractor::Worker
    def initialize(name: nil, **options)
      super
      # Setup database connection and resources
      # Use Ractor.make_shareable to make the hash shareable across Ractors
      @db_connection = Ractor.make_shareable({ pool_size: 5, timeout: 30 })
    end

    def process(work)
      # Only handle DatabaseWork - check work_type for Ractor compatibility
      unless work.respond_to?(:work_type) && work.work_type == :database
        return Fractor::WorkResult.new(
          error: "DatabaseWorker can only process DatabaseWork, got: #{work.class}",
          work: work,
        )
      end

      # Process based on query type
      result = case work.query_type
               when :select then perform_select(work.table, work.conditions)
               when :insert then perform_insert(work.table, work.data)
               when :update then perform_update(work.table, work.data,
                                                work.conditions)
               when :delete then perform_delete(work.table, work.conditions)
               else default_query(work.query_type, work.table, work.conditions)
               end

      Fractor::WorkResult.new(
        result: {
          query_type: work.query_type,
          table: work.table,
          rows_affected: result[:rows_affected],
          data: result[:data],
          execution_time: result[:time],
        },
        work: work,
      )
    end

    # Database operation methods
    private

    def perform_select(_table, _conditions)
      # Select query simulation
      sleep(rand(0.01..0.1))
      record_count = rand(0..20)
      {
        rows_affected: record_count,
        data: Array.new(record_count) do |i|
          { id: i + 1, name: "Record #{i + 1}" }
        end,
        time: rand(0.01..0.05),
      }
    end

    def perform_insert(_table, _data)
      # Insert query simulation
      sleep(rand(0.01..0.05))
      {
        rows_affected: 1,
        data: { id: rand(1000..9999) },
        time: rand(0.01..0.03),
      }
    end

    def perform_update(_table, _data, _conditions)
      # Update query simulation
      sleep(rand(0.01..0.1))
      affected = rand(0..10)
      {
        rows_affected: affected,
        data: nil,
        time: rand(0.01..0.05),
      }
    end

    def perform_delete(_table, _conditions)
      # Delete query simulation
      sleep(rand(0.01..0.05))
      affected = rand(0..5)
      {
        rows_affected: affected,
        data: nil,
        time: rand(0.01..0.03),
      }
    end

    def default_query(_type, _table, _conditions)
      # Default query handling
      sleep(rand(0.01..0.02))
      {
        rows_affected: 0,
        data: nil,
        time: rand(0.005..0.01),
      }
    end
  end

  # Controller class that manages both worker types
  class HybridSystem
    attr_reader :compute_results, :db_results

    def initialize(compute_workers: 2, db_workers: 2)
      # Create separate supervisors for each worker type
      @compute_supervisor = Fractor::Supervisor.new(
        worker_pools: [
          { worker_class: ComputeWorker, num_workers: compute_workers },
        ],
      )

      @db_supervisor = Fractor::Supervisor.new(
        worker_pools: [
          { worker_class: DatabaseWorker, num_workers: db_workers },
        ],
      )

      @compute_results = []
      @db_results = []
    end

    def process_mixed_workload(compute_tasks, db_tasks)
      # Create and add compute work items
      compute_work_items = compute_tasks.map do |task|
        ComputeWork.new(task[:data], task[:operation], task[:parameters])
      end
      puts "Created #{compute_work_items.size} compute work items"
      puts "First compute work item: #{compute_work_items.first.inspect}" if compute_work_items.any?
      @compute_supervisor.add_work_items(compute_work_items)
      puts "Added compute work items to supervisor"

      # Create and add database work items
      db_work_items = db_tasks.map do |task|
        DatabaseWork.new(task[:data], task[:query_type], task[:table],
                         task[:conditions])
      end
      puts "Created #{db_work_items.size} database work items"
      puts "First db work item: #{db_work_items.first.inspect}" if db_work_items.any?
      @db_supervisor.add_work_items(db_work_items)
      puts "Added database work items to supervisor"

      # Run the supervisors directly - this is more reliable
      @compute_supervisor.run
      @db_supervisor.run

      # Get results directly from the supervisors
      compute_results_agg = @compute_supervisor.results
      db_results_agg = @db_supervisor.results

      puts "Received compute results: #{compute_results_agg.results.size} items"
      puts "Received compute errors: #{compute_results_agg.errors.size} items"
      if compute_results_agg.errors.any?
        compute_results_agg.errors.each do |e|
          puts "  Error: #{e.error}"
        end
      end
      puts "Received database results: #{db_results_agg.results.size} items"
      puts "Received database errors: #{db_results_agg.errors.size} items"
      if db_results_agg.errors.any?
        db_results_agg.errors.each do |e|
          puts "  Error: #{e.error}"
        end
      end

      # Format and store results
      @compute_results = format_compute_results(compute_results_agg)
      @db_results = format_db_results(db_results_agg)

      # Return combined results
      {
        computation: {
          tasks: compute_tasks.size,
          completed: @compute_results.size,
          results: @compute_results,
        },
        database: {
          tasks: db_tasks.size,
          completed: @db_results.size,
          results: @db_results,
        },
      }
    end

    private

    def format_compute_results(results_aggregator)
      # Format computation results
      results_aggregator.results.map(&:result)
    end

    def format_db_results(results_aggregator)
      # Format database results
      results_aggregator.results.map(&:result)
    end
  end
end

# Example usage
if __FILE__ == $PROGRAM_NAME
  puts "Starting Specialized Workers Example"
  puts "==================================="
  puts "This example demonstrates two specialized worker types:"
  puts "1. ComputeWorker: Handles compute-intensive operations"
  puts "2. DatabaseWorker: Handles database operations"
  puts "Each worker is designed to process a specific type of work."
  puts

  # Prepare compute tasks
  compute_tasks = [
    {
      operation: :matrix_multiply,
      data: "Matrix data...",
      parameters: { size: [10, 10] },
    },
    {
      operation: :image_transform,
      data: "Image data...",
      parameters: { transforms: %i[rotate scale blur], angle: 45, scale: 1.5 },
    },
    {
      operation: :path_finding,
      data: "Graph data...",
      parameters: { algorithm: :dijkstra, nodes: 20, start: 1, end: 15 },
    },
  ]

  # Prepare database tasks
  db_tasks = [
    {
      query_type: :select,
      table: "users",
      conditions: { active: true, role: "admin" },
    },
    {
      query_type: :insert,
      table: "orders",
      data: "Order data...",
    },
    {
      query_type: :update,
      table: "products",
      data: "Product data...",
      conditions: { category: "electronics" },
    },
    {
      query_type: :delete,
      table: "sessions",
      conditions: { expired: true },
    },
  ]

  compute_workers = 2
  db_workers = 2
  puts "Processing with #{compute_workers} compute workers and #{db_workers} database workers..."
  puts

  start_time = Time.now
  system = SpecializedWorkers::HybridSystem.new(
    compute_workers: compute_workers,
    db_workers: db_workers,
  )
  result = system.process_mixed_workload(compute_tasks, db_tasks)
  end_time = Time.now

  puts "Processing Results:"
  puts "-----------------"
  puts "Compute Tasks: #{result[:computation][:tasks]} submitted, #{result[:computation][:completed]} completed"
  puts "Database Tasks: #{result[:database][:tasks]} submitted, #{result[:database][:completed]} completed"
  puts

  puts "Computation Results:"
  result[:computation][:results].each_with_index do |compute_result, index|
    puts "Task #{index + 1} (#{compute_result[:operation]}):"
    puts "  Result: #{compute_result[:computation_result]}"
    puts "  Resources: #{compute_result[:resources_used]}"
    puts
  end

  puts "Database Results:"
  result[:database][:results].each_with_index do |db_result, index|
    puts "Query #{index + 1} (#{db_result[:query_type]} on #{db_result[:table]}):"
    puts "  Rows affected: #{db_result[:rows_affected]}"
    puts "  Execution time: #{db_result[:execution_time]} seconds"
    puts "  Data: #{db_result[:data].to_s[0..60]}..." unless db_result[:data].nil?
    puts
  end

  puts "Processing completed in #{end_time - start_time} seconds"
end
