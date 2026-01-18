# frozen_string_literal: true

require "etc"
require "timeout"
require_relative "signal_handler"
require_relative "error_formatter"

module Fractor
  # Custom exception for shutdown signal handling
  class ShutdownSignal < StandardError; end

  # Supervises multiple WrappedRactors, distributes work, and aggregates results.
  class Supervisor
    attr_reader :work_queue, :workers, :results, :worker_pools, :debug,
                :error_reporter, :logger, :performance_monitor

    # Initializes the Supervisor.
    # - worker_pools: An array of worker pool configurations, each containing:
    #   - worker_class: The class inheriting from Fractor::Worker (e.g., MyWorker).
    #   - num_workers: The number of Ractors to spawn for this worker class.
    # - continuous_mode: Whether to run in continuous mode without expecting a fixed work count.
    # - debug: Enable verbose debugging output for all state changes.
    # - logger: Optional logger instance for this Supervisor (defaults to Fractor.logger).
    #          Provides isolation when multiple gems use Fractor in the same process.
    # - tracer_enabled: Optional override for ExecutionTracer (nil uses global setting).
    # - tracer_stream: Optional trace stream for this Supervisor (nil uses global setting).
    # - enable_performance_monitoring: Enable performance monitoring (latency, throughput, etc.).
    def initialize(worker_pools: [], continuous_mode: false, debug: false, logger: nil,
                   tracer_enabled: nil, tracer_stream: nil, enable_performance_monitoring: false)
      @debug = debug || ENV["FRACTOR_DEBUG"] == "1"
      @logger = logger # Store instance-specific logger for isolation
      @tracer_enabled = tracer_enabled
      @tracer_stream = tracer_stream
      @worker_pools = worker_pools.map.with_index do |pool_config, index|
        worker_class = pool_config[:worker_class]
        num_workers = pool_config[:num_workers] || detect_num_workers

        # Validate worker_class
        unless worker_class.is_a?(Class)
          raise ArgumentError,
                "worker_class must be a Class (got #{worker_class.class}), in worker_pools[#{index}]\n\n" \
                "Expected: { worker_class: MyWorker }\n" \
                "Got:      { worker_class: #{worker_class.inspect} }\n\n" \
                "Fix: Use the class itself, not a symbol or string.\n" \
                "Example: { worker_class: MyWorker }  # Correct\n" \
                "         { worker_class: 'MyWorker' } # Wrong - this is a string"
        end

        unless worker_class < Fractor::Worker
          raise ArgumentError,
                "#{worker_class} must inherit from Fractor::Worker, in worker_pools[#{index}]\n\n" \
                "Your worker class must be defined as:\n" \
                "  class #{worker_class} < Fractor::Worker\n" \
                "    def process(work)\n" \
                "      # ...\n" \
                "    end\n" \
                "  end\n\n" \
                "Did you forget to inherit from Fractor::Worker?"
        end

        # Validate num_workers
        unless num_workers.is_a?(Integer) && num_workers.positive?
          raise ArgumentError,
                "num_workers must be a positive integer (got #{num_workers.inspect}), in worker_pools[#{index}]\n\n" \
                "Valid values: Integer >= 1\n" \
                "Examples: { num_workers: 4 }  # Use 4 workers\n" \
                "          { num_workers: Etc.nprocessors }  # Use available CPUs"
        end

        {
          worker_class: worker_class,
          num_workers: num_workers,
          workers: [], # Will hold the WrappedRactor instances
        }
      end

      @work_queue = Queue.new
      @results = ResultAggregator.new
      @workers = [] # Flattened array of all workers across all pools
      @total_work_count = 0 # Track total items initially added
      @ractors_map = {} # Map Ractor object to WrappedRactor instance
      @continuous_mode = continuous_mode
      @running = false
      @work_callbacks = []
      @wakeup_ractor = nil # Control ractor for unblocking select
      @timer_thread = nil # Timer thread for periodic wakeup
      @error_reporter = ErrorReporter.new # Track errors and statistics
      @error_callbacks = [] # Custom error callbacks
      @performance_monitor = nil # Performance monitor instance

      # Initialize performance monitor if enabled
      if enable_performance_monitoring
        require_relative "performance_monitor"
        @performance_monitor = PerformanceMonitor.new(self)
        @performance_monitor.start
      end

      # Initialize work distribution manager (handles idle workers and work assignment)
      @work_distribution_manager = WorkDistributionManager.new(
        @work_queue,
        @workers,
        @ractors_map,
        debug: @debug,
        continuous_mode: @continuous_mode,
        performance_monitor: @performance_monitor
      )

      # Initialize shutdown handler (manages graceful shutdown)
      @shutdown_handler = ShutdownHandler.new(
        @workers,
        @wakeup_ractor,
        @timer_thread,
        @performance_monitor,
        debug: @debug
      )

      # Initialize signal handler for graceful shutdown
      @signal_handler = SignalHandler.new(
        continuous_mode: @continuous_mode,
        debug: @debug,
        status_callback: -> { print_status },
        shutdown_callback: ->(mode) { handle_shutdown_callback(mode) }
      )

      # Initialize error formatter for error messages
      @error_formatter = ErrorFormatter.new
    end

    # Adds a single work item to the queue.
    # The item must be an instance of Fractor::Work or a subclass.
    def add_work_item(work)
      unless work.is_a?(Fractor::Work)
        raise ArgumentError,
              "#{work.class} must be an instance of Fractor::Work.\n\n" \
              "Received: #{work.inspect}\n\n" \
              "To create a valid work item:\n" \
              "  class MyWork < Fractor::Work\n" \
              "    def initialize(data)\n" \
              "      super({ value: data })\n" \
              "    end\n" \
              "  end\n\n" \
              "  work = MyWork.new(42)\n" \
              "  supervisor.add_work_item(work)"
      end

      @work_queue << work
      @total_work_count += 1

      # Trace work item queued
      trace_work(:queued, work, queue_size: @work_queue.size)

      return unless @debug

      puts "Work item added. Initial work count: #{@total_work_count}, Queue size: #{@work_queue.size}"
    end

    # Adds multiple work items to the queue.
    # Each item must be an instance of Fractor::Work or a subclass.
    def add_work_items(works)
      works.each do |work|
        add_work_item(work)
      end
    end

    # Register a callback to provide new work items
    # The callback should return nil or empty array when no new work is available
    def register_work_source(&callback)
      @work_callbacks << callback
    end

    # Register a callback to handle errors
    # The callback receives (error_result, worker_name, worker_class)
    # Example: supervisor.on_error { |err, worker, klass| puts "Error in #{klass}: #{err.error}" }
    def on_error(&callback)
      @error_callbacks << callback
    end

    # Starts the worker Ractors for all worker pools.
    def start_workers
      # Create a wakeup Ractor for unblocking Ractor.select
      @wakeup_ractor = Ractor.new do
        puts "Wakeup Ractor started" if @debug
        loop do
          msg = Ractor.receive
          puts "Wakeup Ractor received: #{msg.inspect}" if @debug
          if %i[wakeup shutdown].include?(msg)
            Ractor.yield({ type: :wakeup, message: msg })
            break if msg == :shutdown
          end
        end
        puts "Wakeup Ractor shutting down" if @debug
      end

      # Add wakeup ractor to the map with a special marker
      @ractors_map[@wakeup_ractor] = :wakeup

      @worker_pools.each do |pool|
        worker_class = pool[:worker_class]
        num_workers = pool[:num_workers]

        pool[:workers] = (1..num_workers).map do |i|
          wrapped_ractor = WrappedRactor.new("worker #{worker_class}:#{i}", worker_class)
          wrapped_ractor.start # Start the underlying Ractor
          # Map the actual Ractor object to the WrappedRactor instance
          @ractors_map[wrapped_ractor.ractor] = wrapped_ractor if wrapped_ractor.ractor
          wrapped_ractor
        end.compact
      end

      # Flatten all workers for easier access
      @workers = @worker_pools.flat_map { |pool| pool[:workers] }
      @ractors_map.compact! # Ensure map doesn't contain nil keys/values
      return unless @debug

      puts "Workers started: #{@workers.size} active across #{@worker_pools.size} pools."
    end

    # Sets up signal handlers for graceful shutdown.
    # Uses SignalHandler to manage signal handling logic.
    def setup_signal_handler
      @signal_handler.setup
    end

    # Callback for signal handler shutdown requests.
    def handle_shutdown_callback(mode)
      if mode == :graceful
        stop
      else
        # Immediate shutdown - raise signal in current thread
        Thread.current.raise(ShutdownSignal, "Interrupted by signal")
      end
    end

    # Prints current supervisor status
    def print_status
      status = @work_distribution_manager.status_summary
      puts "\n=== Fractor Supervisor Status ==="
      puts "Mode: #{@continuous_mode ? 'Continuous' : 'Batch'}"
      puts "Running: #{@running}"
      puts "Workers: #{@workers.size}"
      puts "Idle workers: #{status[:idle]}"
      puts "Queue size: #{@work_queue.size}"
      puts "Results: #{@results.results.size}"
      puts "Errors: #{@results.errors.size}"
      puts "================================\n"
    end

    # Starts the supervisor (alias for run).
    # Provides a consistent API with stop method.
    #
    # @see #run
    def start
      run
    end

    # Runs the main processing loop.
    def run
      setup_signal_handler
      start_workers

      @running = true

      # Start timer thread for continuous mode to periodically check work sources
      start_timer_thread if @continuous_mode && !@work_callbacks.empty?

      begin
        # Run the main event loop through MainLoopHandler
        main_loop_handler = MainLoopHandler.new(self, debug: @debug)
        main_loop_handler.run_loop
      rescue ShutdownSignal => e
        puts "Shutdown signal caught: #{e.message}" if @debug
        puts "Sending shutdown message to all Ractors..." if @debug

        # Send shutdown message to each worker Ractor
        @workers.each do |w|
          w.send(:shutdown)
          puts "Sent shutdown to Ractor: #{w.name}" if @debug
        rescue StandardError => send_error
          puts "Error sending shutdown to Ractor #{w.name}: #{send_error.message}" if @debug
        end

        puts "Exiting due to shutdown signal." if @debug
        exit!(1) # Force exit immediately
      end

      return if @continuous_mode

      return unless @debug

      puts "Final Aggregated Results: #{@results.inspect}"
    end

    # Stop the supervisor (for continuous mode)
    def stop
      @running = false
      puts "Stopping supervisor..." if @debug

      # Update shutdown handler with current references before shutdown
      @shutdown_handler.instance_variable_set(:@workers, @workers)
      @shutdown_handler.instance_variable_set(:@wakeup_ractor, @wakeup_ractor)
      @shutdown_handler.instance_variable_set(:@timer_thread, @timer_thread)
      @shutdown_handler.instance_variable_set(:@performance_monitor, @performance_monitor)

      @shutdown_handler.shutdown
    end

    private

    # Start the timer thread for continuous mode.
    # This thread periodically wakes up the main loop to check for new work.
    #
    # @return [void]
    def start_timer_thread
      @timer_thread = Thread.new do
        while @running
          sleep(0.1) # Check work sources every 100ms
          if @wakeup_ractor && @running
            begin
              @wakeup_ractor.send(:wakeup)
            rescue StandardError => e
              puts "Timer thread error sending wakeup: #{e.message}" if @debug
              break
            end
          end
        end
        puts "Timer thread shutting down" if @debug
      end
    end

    # Format error context with rich information for debugging.
    # Uses ErrorFormatter to generate formatted error messages.
    #
    # @param wrapped_ractor [WrappedRactor] The worker that encountered the error
    # @param error_result [WorkResult] The error result
    # @return [String] Formatted error message with context
    def format_error_context(wrapped_ractor, error_result)
      @error_formatter.format(wrapped_ractor, error_result)
    end

    # Trace a work event using instance-specific or global tracer configuration.
    # This allows multiple Supervisors to have independent tracer settings.
    # @param event [Symbol] The event type (:queued, :completed, :failed, etc.)
    # @param work [Work] The work item
    # @param context [Hash] Additional context (worker_name, worker_class, etc.)
    def trace_work(event, work = nil, context = {})
      # Check if instance-specific tracing is configured
      if @tracer_enabled.nil? && @tracer_stream.nil?
        # No instance config - use global ExecutionTracer
        Fractor::ExecutionTracer.trace(event, work, context)
        return
      end

      # Instance-specific tracing - do it here
      enabled = @tracer_enabled.nil? ? ExecutionTracer.enabled? : @tracer_enabled
      return unless enabled

      stream = @tracer_stream || ExecutionTracer.trace_stream
      timestamp = Time.now.strftime("%Y-%m-%d %H:%M:%S.%3N")
      thread_id = Thread.current.object_id

      # Build trace line (simplified version of ExecutionTracer logic)
      parts = [
        "[TRACE]",
        timestamp,
        "[T#{thread_id}]",
        event.to_s.upcase,
      ]

      if work
        work_info = work.instance_of?(::Fractor::Work) ? "Work" : work.class.name
        parts << "#{work_info}:#{work.object_id}"
      end

      if context[:worker_name]
        parts << "worker=#{context[:worker_name]}"
      end
      if context[:worker_class]
        parts << "class=#{context[:worker_class]}"
      end
      if context[:duration_ms]
        parts << "duration=#{context[:duration_ms]}ms"
      end
      if context[:queue_size]
        parts << "queue_size=#{context[:queue_size]}"
      end

      stream.puts(parts.join(" "))
    end

    # Detects the number of available processors on the system.
    # Returns the number of processors, or 2 as a fallback if detection fails.
    def detect_num_workers
      num_processors = Etc.nprocessors
      puts "Auto-detected #{num_processors} available processors" if @debug
      num_processors
    rescue StandardError => e
      puts "Failed to detect processors: #{e.message}. Using default of 2 workers." if @debug
      2
    end

    public

    # ============================================
    # DEBUGGING METHODS
    # ============================================

    # Inspect the current state of the work queue
    # Returns a hash with queue information and items
    def inspect_queue
      items = []
      # Queue doesn't have to_a, need to iterate
      temp_queue = Queue.new
      until @work_queue.empty?
        item = @work_queue.pop
        items << item
        temp_queue.push(item)
      end
      # Restore the queue
      until temp_queue.empty?
        @work_queue.push(temp_queue.pop)
      end

      {
        size: @work_queue.size,
        total_added: @total_work_count,
        items: items.map do |work|
          {
            class: work.class.name,
            input: work.input,
            inspect: work.inspect
          }
        end
      }
    end

    # Get current worker status
    # Returns a hash with worker statistics
    def workers_status
      status = @work_distribution_manager.status_summary
      idle_count = status[:idle]
      busy_count = status[:busy]

      {
        total: @workers.size,
        idle: idle_count,
        busy: busy_count,
        pools: @worker_pools.map do |pool|
          {
            worker_class: pool[:worker_class].name,
            num_workers: pool[:num_workers],
            workers: pool[:workers].map do |w|
              {
                name: w.name,
                idle: @work_distribution_manager.idle_workers_list.include?(w)
              }
            end
          }
        end
      }
    end

    # Enable debug mode for verbose output
    def debug!
      @debug = true
    end

    # Disable debug mode
    def debug_off!
      @debug = false
    end

    # Check if debug mode is enabled
    def debug?
      @debug
    end

    # Get performance metrics snapshot if performance monitoring is enabled
    # Returns nil if performance monitoring is not enabled
    def performance_metrics
      return nil unless @performance_monitor

      @performance_monitor.snapshot
    end
  end
end
