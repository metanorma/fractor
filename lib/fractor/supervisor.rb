# frozen_string_literal: true

require "etc"
require "timeout"

module Fractor
  # Custom exception for shutdown signal handling
  class ShutdownSignal < StandardError; end

  # Supervises multiple WrappedRactors, distributes work, and aggregates results.
  class Supervisor
    attr_reader :work_queue, :workers, :results, :worker_pools

    # Initializes the Supervisor.
    # - worker_pools: An array of worker pool configurations, each containing:
    #   - worker_class: The class inheriting from Fractor::Worker (e.g., MyWorker).
    #   - num_workers: The number of Ractors to spawn for this worker class.
    # - continuous_mode: Whether to run in continuous mode without expecting a fixed work count.
    def initialize(worker_pools: [], continuous_mode: false)
      @worker_pools = worker_pools.map do |pool_config|
        worker_class = pool_config[:worker_class]
        num_workers = pool_config[:num_workers] || detect_num_workers

        unless worker_class < Fractor::Worker
          raise ArgumentError,
                "#{worker_class} must inherit from Fractor::Worker"
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
      @idle_workers = [] # Track workers waiting for work
    end

    # Adds a single work item to the queue.
    # The item must be an instance of Fractor::Work or a subclass.
    def add_work_item(work)
      unless work.is_a?(Fractor::Work)
        raise ArgumentError,
              "#{work.class} must be an instance of Fractor::Work"
      end

      @work_queue << work
      @total_work_count += 1
      return unless ENV["FRACTOR_DEBUG"]

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

    # Starts the worker Ractors for all worker pools.
    def start_workers
      # Create a wakeup Ractor for unblocking Ractor.select
      @wakeup_ractor = Ractor.new do
        puts "Wakeup Ractor started" if ENV["FRACTOR_DEBUG"]
        loop do
          msg = Ractor.receive
          puts "Wakeup Ractor received: #{msg.inspect}" if ENV["FRACTOR_DEBUG"]
          if %i[wakeup shutdown].include?(msg)
            Ractor.yield({ type: :wakeup, message: msg })
            break if msg == :shutdown
          end
        end
        puts "Wakeup Ractor shutting down" if ENV["FRACTOR_DEBUG"]
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
      return unless ENV["FRACTOR_DEBUG"]

      puts "Workers started: #{@workers.size} active across #{@worker_pools.size} pools."
    end

    # Sets up signal handlers for graceful shutdown.
    # Handles SIGINT (Ctrl+C), SIGTERM (systemd/docker), and platform-specific status signals.
    def setup_signal_handler
      # Universal signals (work on all platforms)
      Signal.trap("INT") { handle_shutdown("SIGINT") }
      Signal.trap("TERM") { handle_shutdown("SIGTERM") }

      # Platform-specific status monitoring
      setup_status_signal
    end

    # Handles shutdown signal by mode (continuous vs batch)
    def handle_shutdown(signal_name)
      if @continuous_mode
        puts "\n#{signal_name} received. Initiating graceful shutdown..." if ENV["FRACTOR_DEBUG"]
        stop
      else
        puts "\n#{signal_name} received. Initiating immediate shutdown..." if ENV["FRACTOR_DEBUG"]
        Thread.current.raise(ShutdownSignal, "Interrupted by #{signal_name}")
      end
    rescue Exception => e
      puts "Error in signal handler: #{e.class}: #{e.message}" if ENV["FRACTOR_DEBUG"]
      puts e.backtrace.join("\n") if ENV["FRACTOR_DEBUG"]
      exit!(1)
    end

    # Sets up platform-specific status monitoring signal
    def setup_status_signal
      if Gem.win_platform?
        # Windows: Use SIGBREAK (Ctrl+Break)
        Signal.trap("BREAK") { print_status }
      else
        # Unix/Linux/macOS: Use SIGUSR1
        begin
          Signal.trap("USR1") { print_status }
        rescue ArgumentError
          # SIGUSR1 not supported on this platform
        end
      end
    end

    # Prints current supervisor status
    def print_status
      puts "\n=== Fractor Supervisor Status ==="
      puts "Mode: #{@continuous_mode ? 'Continuous' : 'Batch'}"
      puts "Running: #{@running}"
      puts "Workers: #{@workers.size}"
      puts "Idle workers: #{@idle_workers.size}"
      puts "Queue size: #{@work_queue.size}"
      puts "Results: #{@results.results.size}"
      puts "Errors: #{@results.errors.size}"
      puts "================================\n"
    end

    # Runs the main processing loop.
    def run
      setup_signal_handler
      start_workers

      @running = true
      processed_count = 0

      # Start timer thread for continuous mode to periodically check work sources
      if @continuous_mode && !@work_callbacks.empty?
        @timer_thread = Thread.new do
          while @running
            sleep(0.1) # Check work sources every 100ms
            if @wakeup_ractor && @running
              begin
                @wakeup_ractor.send(:wakeup)
              rescue StandardError => e
                puts "Timer thread error sending wakeup: #{e.message}" if ENV["FRACTOR_DEBUG"]
                break
              end
            end
          end
          puts "Timer thread shutting down" if ENV["FRACTOR_DEBUG"]
        end
      end

      begin
        # Main loop: Process events until conditions are met for termination
        while @running && (@continuous_mode || processed_count < @total_work_count)
          processed_count = @results.results.size + @results.errors.size

          if ENV["FRACTOR_DEBUG"]
            if @continuous_mode
              puts "Continuous mode: Waiting for Ractor results. Processed: #{processed_count}, Queue size: #{@work_queue.size}"
            else
              puts "Waiting for Ractor results. Processed: #{processed_count}/#{@total_work_count}, Queue size: #{@work_queue.size}"
            end
          end

          # Get active Ractor objects from the map keys
          active_ractors = @ractors_map.keys

          # Check for new work from callbacks if in continuous mode
          if @continuous_mode && !@work_callbacks.empty?
            @work_callbacks.each do |callback|
              new_work = callback.call
              if new_work && !new_work.empty?
                add_work_items(new_work)
                puts "Work source provided #{new_work.size} new items" if ENV["FRACTOR_DEBUG"]

                # Try to send work to idle workers first
                while !@work_queue.empty? && !@idle_workers.empty?
                  worker = @idle_workers.shift
                  if send_next_work_if_available(worker)
                    puts "Sent work to idle worker #{worker.name}" if ENV["FRACTOR_DEBUG"]
                  else
                    # Worker couldn't accept work, don't re-add to idle list
                  end
                end
              end
            end
          end

          # Break if no active workers and queue is empty, but work remains (indicates potential issue)
          if active_ractors.empty? && @work_queue.empty? && !@continuous_mode && processed_count < @total_work_count
            puts "Warning: No active workers and queue is empty, but not all work is processed. Exiting loop." if ENV["FRACTOR_DEBUG"]
            break
          end

          # In continuous mode, just wait if no active ractors but keep running
          if active_ractors.empty?
            break unless @continuous_mode

            sleep(0.1) # Small delay to avoid CPU spinning
            next
          end

          # Ractor.select blocks until a message is available from any active Ractor
          # The wakeup ractor ensures we can unblock this call when needed
          ready_ractor_obj, message = Ractor.select(*active_ractors)

          # Check if this is the wakeup ractor
          if ready_ractor_obj == @wakeup_ractor
            puts "Wakeup signal received: #{message[:message]}" if ENV["FRACTOR_DEBUG"]
            # Remove wakeup ractor from map if shutting down
            if message[:message] == :shutdown
              @ractors_map.delete(@wakeup_ractor)
              @wakeup_ractor = nil
            end
            # Continue loop to check @running flag
            next
          end

          # Find the corresponding WrappedRactor instance
          wrapped_ractor = @ractors_map[ready_ractor_obj]
          unless wrapped_ractor
            puts "Warning: Received message from unknown Ractor: #{ready_ractor_obj}. Ignoring." if ENV["FRACTOR_DEBUG"]
            next
          end

          puts "Selected Ractor: #{wrapped_ractor.name}, Message Type: #{message[:type]}" if ENV["FRACTOR_DEBUG"]

          # Process the received message
          case message[:type]
          when :initialize
            puts "Ractor initialized: #{message[:processor]}" if ENV["FRACTOR_DEBUG"]
            # Send work immediately upon initialization if available
            if send_next_work_if_available(wrapped_ractor)
              # Work was sent
            else
              # No work available, mark worker as idle
              @idle_workers << wrapped_ractor unless @idle_workers.include?(wrapped_ractor)
              puts "Worker #{wrapped_ractor.name} marked as idle" if ENV["FRACTOR_DEBUG"]
            end
          when :shutdown
            puts "Ractor #{wrapped_ractor.name} acknowledged shutdown" if ENV["FRACTOR_DEBUG"]
            # Remove from active ractors
            @ractors_map.delete(ready_ractor_obj)
          when :result
            # The message[:result] should be a WorkResult object
            work_result = message[:result]
            puts "Completed work: #{work_result.inspect} in Ractor: #{message[:processor]}" if ENV["FRACTOR_DEBUG"]
            @results.add_result(work_result)
            if ENV["FRACTOR_DEBUG"]
              puts "Result processed. Total processed: #{@results.results.size + @results.errors.size}"
              puts "Aggregated Results: #{@results.inspect}" unless @continuous_mode
            end
            # Send next piece of work
            if send_next_work_if_available(wrapped_ractor)
              # Work was sent
            else
              # No work available, mark worker as idle
              @idle_workers << wrapped_ractor unless @idle_workers.include?(wrapped_ractor)
              puts "Worker #{wrapped_ractor.name} marked as idle after completing work" if ENV["FRACTOR_DEBUG"]
            end
          when :error
            # The message[:result] should be a WorkResult object containing the error
            error_result = message[:result]
            puts "Error processing work #{error_result.work&.inspect} in Ractor: #{message[:processor]}: #{error_result.error}" if ENV["FRACTOR_DEBUG"]
            @results.add_result(error_result) # Add error to aggregator
            if ENV["FRACTOR_DEBUG"]
              puts "Error handled. Total processed: #{@results.results.size + @results.errors.size}"
              puts "Aggregated Results (including errors): #{@results.inspect}" unless @continuous_mode
            end
            # Send next piece of work even after an error
            if send_next_work_if_available(wrapped_ractor)
              # Work was sent
            else
              # No work available, mark worker as idle
              @idle_workers << wrapped_ractor unless @idle_workers.include?(wrapped_ractor)
              puts "Worker #{wrapped_ractor.name} marked as idle after error" if ENV["FRACTOR_DEBUG"]
            end
          else
            puts "Unknown message type received: #{message[:type]} from #{wrapped_ractor.name}" if ENV["FRACTOR_DEBUG"]
          end
          # Update processed count for the loop condition
          processed_count = @results.results.size + @results.errors.size
        end

        puts "Main loop finished." if ENV["FRACTOR_DEBUG"]
      rescue ShutdownSignal => e
        puts "Shutdown signal caught: #{e.message}" if ENV["FRACTOR_DEBUG"]
        puts "Sending shutdown message to all Ractors..." if ENV["FRACTOR_DEBUG"]

        # Send shutdown message to each worker Ractor
        @workers.each do |w|
          w.send(:shutdown)
          puts "Sent shutdown to Ractor: #{w.name}" if ENV["FRACTOR_DEBUG"]
        rescue StandardError => send_error
          puts "Error sending shutdown to Ractor #{w.name}: #{send_error.message}" if ENV["FRACTOR_DEBUG"]
        end

        puts "Exiting due to shutdown signal." if ENV["FRACTOR_DEBUG"]
        exit!(1) # Force exit immediately
      end

      return if @continuous_mode

      return unless ENV["FRACTOR_DEBUG"]

      puts "Final Aggregated Results: #{@results.inspect}"
    end

    # Stop the supervisor (for continuous mode)
    def stop
      @running = false
      puts "Stopping supervisor..." if ENV["FRACTOR_DEBUG"]

      # Wait for timer thread to finish if it exists
      if @timer_thread&.alive?
        @timer_thread.join(1) # Wait up to 1 second
        puts "Timer thread stopped" if ENV["FRACTOR_DEBUG"]
      end

      # Signal the wakeup ractor first to unblock Ractor.select
      if @wakeup_ractor
        begin
          @wakeup_ractor.send(:shutdown)
          puts "Sent shutdown signal to wakeup ractor" if ENV["FRACTOR_DEBUG"]
        rescue StandardError => e
          puts "Error sending shutdown to wakeup ractor: #{e.message}" if ENV["FRACTOR_DEBUG"]
        end
      end

      # Send shutdown signal to all workers
      @workers.each do |w|
        begin
          w.send(:shutdown)
        rescue StandardError
          nil
        end
        puts "Sent shutdown signal to #{w.name}" if ENV["FRACTOR_DEBUG"]
      end
    end

    private

    # Detects the number of available processors on the system.
    # Returns the number of processors, or 2 as a fallback if detection fails.
    def detect_num_workers
      num_processors = Etc.nprocessors
      puts "Auto-detected #{num_processors} available processors" if ENV["FRACTOR_DEBUG"]
      num_processors
    rescue StandardError => e
      puts "Failed to detect processors: #{e.message}. Using default of 2 workers." if ENV["FRACTOR_DEBUG"]
      2
    end

    # Helper method to send the next available work item to a specific Ractor.
    # Returns true if work was sent, false otherwise.
    def send_next_work_if_available(wrapped_ractor)
      # Ensure the wrapped_ractor instance is valid and its underlying ractor is not closed
      if wrapped_ractor && !wrapped_ractor.closed?
        if @work_queue.empty?
          puts "Work queue empty. Not sending new work to Ractor #{wrapped_ractor.name}." if ENV["FRACTOR_DEBUG"]
          # In continuous mode, don't close workers as more work may come
          unless @continuous_mode
            # Consider closing the Ractor if the queue is empty and no more work is expected.
            # wrapped_ractor.close
            # @ractors_map.delete(wrapped_ractor.ractor)
            # if ENV["FRACTOR_DEBUG"]
            #   puts "Closed idle Ractor: #{wrapped_ractor.name}"
            # end
          end
          false
        else
          work_item = @work_queue.pop # Now directly a Work object

          puts "Sending next work #{work_item.inspect} to Ractor: #{wrapped_ractor.name}" if ENV["FRACTOR_DEBUG"]
          wrapped_ractor.send(work_item) # Send the Work object
          puts "Work sent to #{wrapped_ractor.name}." if ENV["FRACTOR_DEBUG"]

          # Remove from idle workers list since it's now busy
          @idle_workers.delete(wrapped_ractor)
          true
        end
      else
        puts "Attempted to send work to an invalid or closed Ractor: #{wrapped_ractor&.name || 'unknown'}." if ENV["FRACTOR_DEBUG"]
        # Remove from map if found but closed
        @ractors_map.delete(wrapped_ractor.ractor) if wrapped_ractor && @ractors_map.key?(wrapped_ractor.ractor)
        false
      end
    end
  end
end
