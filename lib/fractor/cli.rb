# frozen_string_literal: true

require "thor"

module Fractor
  # Main Fractor CLI
  class Cli < Thor
    class_option :verbose, type: :boolean, aliases: "-v",
                           desc: "Enable verbose output"
    class_option :debug, type: :boolean, aliases: "-d",
                         desc: "Enable debug logging"

    # Validate command
    desc "validate FILE", "Validate a workflow definition file"
    def validate(file)
      setup_logging

      unless File.exist?(file)
        warn "Error: File not found: #{file}"
        exit 1
      end

      begin
        # Load and validate the workflow
        workflow = load_workflow_class(file)

        puts "✓ Valid workflow: #{workflow.workflow_name}"
        puts "  Mode: #{workflow.workflow_mode}"
        puts "  Jobs: #{workflow.jobs.size}"

        # Validate each job
        workflow.jobs.each do |name, job|
          puts "  - #{name} (#{job.worker_class})"
          puts "    Input: #{job.input_type}" if job.input_type
          puts "    Output: #{job.output_type}" if job.output_type
          puts "    Needs: #{job.needs.join(', ')}" if job.needs.any?
        end
      rescue StandardError => e
        warn "Error: #{e.class}: #{e.message}"
        warn e.backtrace.first(5) if options[:verbose]
        exit 1
      end
    end

    # Visualize command
    desc "visualize FILE", "Visualize a workflow definition"
    method_option :format, type: :string, default: "ascii", aliases: "-f",
                           desc: "Output format: ascii, mermaid, dot"
    method_option :output, type: :string, aliases: "-o",
                           desc: "Output file (default: stdout)"

    def visualize(file)
      setup_logging

      unless File.exist?(file)
        warn "Error: File not found: #{file}"
        exit 1
      end

      begin
        workflow = load_workflow_class(file)
        visualizer = Fractor::Workflow::Visualizer.new(workflow)

        output = case options[:format].to_sym
                 when :mermaid
                   visualizer.to_mermaid
                 when :dot
                   visualizer.to_dot
                 else
                   visualizer.to_ascii
                 end

        if options[:output]
          File.write(options[:output], output)
          puts "Visualization written to: #{options[:output]}"
        else
          puts output
        end
      rescue StandardError => e
        warn "Error: #{e.class}: #{e.message}"
        warn e.backtrace.first(5) if options[:verbose]
        exit 1
      end
    end

    # Execute command
    desc "execute FILE", "Execute a workflow with optional input data"
    method_option :input, type: :string, aliases: "-i",
                          desc: "Input data (JSON string or file path)"
    method_option :workers, type: :numeric, aliases: "-w",
                            desc: "Number of workers to use"
    method_option :continuous, type: :boolean, aliases: "-c",
                               desc: "Run in continuous mode"

    def execute(file)
      setup_logging

      unless File.exist?(file)
        warn "Error: File not found: #{file}"
        exit 1
      end

      begin
        workflow = load_workflow_class(file)
        input_data = parse_input_data

        instance = workflow.new

        puts "Running workflow: #{workflow.workflow_name}"
        puts "Mode: #{workflow.workflow_mode}"
        puts "Input: #{input_data.inspect}" if options[:verbose]

        start_time = Time.now
        result = instance.execute(input: input_data)
        elapsed = Time.now - start_time

        puts "\nWorkflow completed in #{elapsed.round(3)}s"

        if result.success?
          puts "Status: ✓ SUCCESS"
          puts "Result: #{result.result.inspect}" if result.result
        else
          puts "Status: ✗ FAILED"
          puts "Error: #{result.error}" if result.error
        end

        puts "Jobs completed: #{result.jobs_completed}" if result.jobs_completed
        puts "Jobs failed: #{result.jobs_failed}" if result.jobs_failed

        exit(result.success? ? 0 : 1)
      rescue StandardError => e
        warn "Error: #{e.class}: #{e.message}"
        warn e.backtrace.first(5) if options[:verbose]
        exit 1
      end
    end

    # Supervisor command
    desc "supervisor WORKER_CLASS [INPUTS]",
         "Run work items using Supervisor mode"
    method_option :workers, type: :numeric, aliases: "-w", default: 4,
                            desc: "Number of workers to use"
    method_option :input, type: :string, aliases: "-i",
                          desc: "Input data file (JSON)"
    method_option :continuous, type: :boolean, aliases: "-c",
                               desc: "Run in continuous mode"
    method_option :metrics, type: :boolean, aliases: "-m",
                            desc: "Show performance metrics"

    def supervisor(worker_class, *inputs)
      setup_logging

      begin
        # Load the worker class
        worker = load_worker_class(worker_class)

        # Parse input data if provided
        work_items = if options[:input]
                       parse_input_file(options[:input])
                     elsif inputs.any?
                       inputs.map { |input| Fractor::Work.new(input) }
                     else
                       warn "Error: No input data provided. Use --input FILE or provide INPUTS"
                       exit 1
                     end

        num_workers = options[:workers] || 4
        continuous_mode = options[:continuous] || false

        puts "Starting Fractor Supervisor..."
        puts "Worker: #{worker}"
        puts "Workers: #{num_workers}"
        puts "Mode: #{continuous_mode ? 'Continuous' : 'Batch'}"
        puts "Work items: #{work_items.size}"
        puts

        supervisor = Fractor::Supervisor.new(
          worker_pools: [{ worker_class: worker, num_workers: num_workers }],
          continuous_mode: continuous_mode,
        )

        # Add work items
        work_items.each { |item| supervisor.add_work_item(item) }

        # Run supervisor
        start_time = Time.now
        supervisor.run
        elapsed = Time.now - start_time

        results = supervisor.results

        puts
        puts "Completed in #{elapsed.round(3)}s"
        puts "Results: #{results.results.size} successful"
        puts "Errors: #{results.errors.size} failed"

        if options[:metrics] && defined?(Fractor::PerformanceMonitor)
          show_metrics(supervisor)
        end

        # Exit with error code if any failures
        exit(results.errors.empty? ? 0 : 1)
      rescue StandardError => e
        warn "Error: #{e.class}: #{e.message}"
        warn e.backtrace.first(5) if options[:verbose]
        exit 1
      end
    end

    desc "version", "Show Fractor version"
    def version
      puts "Fractor #{Fractor::VERSION}"
    end

    private

    def setup_logging
      Fractor.enable_logging if options[:debug]
    end

    def load_workflow_class(file)
      workflow_code = File.read(file)
      binding = TOPLEVEL_BINDING.dup
      workflow = eval(workflow_code, binding, file)

      unless workflow.is_a?(Class) && workflow < Fractor::Workflow
        raise ArgumentError, "File does not contain a valid Workflow class"
      end

      workflow
    end

    def load_worker_class(worker_class)
      # Try to load from a file first
      file = File.exist?(worker_class) ? worker_class : "#{worker_class}.rb"

      if File.exist?(file)
        load file
        # Extract class name from file
        class_name = File.basename(file,
                                   ".rb").split("_").map(&:capitalize).join
        const_get(class_name)
      else
        # Try to resolve as a constant
        worker_class.split("::").inject(Object) do |obj, name|
          obj&.const_get(name)
        end
      end
    end

    def parse_input_data
      return nil unless options[:input]

      input = options[:input]

      # Check if it's a file path
      if File.exist?(input)
        JSON.parse(File.read(input))
      else
        # Try to parse as JSON
        JSON.parse(input)
      end
    rescue JSON::ParserError
      warn "Error: Invalid JSON input"
      exit 1
    end

    def parse_input_file(file)
      data = if File.exist?(file)
               JSON.parse(File.read(file))
             else
               [{ input: file }] # Treat as simple string input
             end

      data.map { |item| Fractor::Work.new(item) }
    rescue JSON::ParserError
      warn "Error: Invalid JSON in input file: #{file}"
      exit 1
    end

    def show_metrics(supervisor)
      puts "\nPerformance Metrics:"
      # Basic metrics from supervisor
      puts "  Workers: #{supervisor.workers.size}"
      puts "  Queue depth: #{supervisor.work_queue.size}"
    end
  end
end
