# frozen_string_literal: true

require 'etc'

module Fractor
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

        raise ArgumentError, "#{worker_class} must inherit from Fractor::Worker" unless worker_class < Fractor::Worker

        {
          worker_class: worker_class,
          num_workers: num_workers,
          workers: [] # Will hold the WrappedRactor instances
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
    end

    # Adds a single work item to the queue.
    # The item must be an instance of Fractor::Work or a subclass.
    def add_work_item(work)
      raise ArgumentError, "#{work.class} must be an instance of Fractor::Work" unless work.is_a?(Fractor::Work)

      @work_queue << work
      @total_work_count += 1
      return unless ENV["FRACTOR_DEBUG"]

      puts "Work item added. Initial work count: #{@total_work_count}, Queue size: #{@work_queue.size}"
    end

    # Alias for better naming
    alias add_work_item add_work_item

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

    # Sets up a signal handler for graceful shutdown (Ctrl+C).
    def setup_signal_handler
      # Store instance variables in local variables for the signal handler
      workers_ref = @workers

      # Trap INT signal (Ctrl+C)
      Signal.trap("INT") do
        puts "\nCtrl+C received. Initiating immediate shutdown..." if ENV["FRACTOR_DEBUG"]

        # Set running to false to break the main loop
        @running = false

        puts "Sending shutdown message to all Ractors..." if ENV["FRACTOR_DEBUG"]

        # Send shutdown message to each worker Ractor
        workers_ref.each do |w|
          w.send(:shutdown)
          puts "Sent shutdown to Ractor: #{w.name}" if ENV["FRACTOR_DEBUG"]
        rescue StandardError => e
          puts "Error sending shutdown to Ractor #{w.name}: #{e.message}" if ENV["FRACTOR_DEBUG"]
        end

        puts "Exiting now." if ENV["FRACTOR_DEBUG"]
        exit!(1) # Use exit! to exit immediately without running at_exit handlers
      rescue Exception => e
        puts "Error in signal handler: #{e.class}: #{e.message}" if ENV["FRACTOR_DEBUG"]
        puts e.backtrace.join("\n") if ENV["FRACTOR_DEBUG"]
        exit!(1)
      end
    end

    # Runs the main processing loop.
    def run
      setup_signal_handler
      start_workers

      @running = true
      processed_count = 0

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

        # Check for new work from callbacks if in continuous mode and queue is empty
        if @continuous_mode && @work_queue.empty? && !@work_callbacks.empty?
          @work_callbacks.each do |callback|
            new_work = callback.call
            add_work_items(new_work) if new_work && !new_work.empty?
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
        ready_ractor_obj, message = Ractor.select(*active_ractors)

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
          send_next_work_if_available(wrapped_ractor)
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
          send_next_work_if_available(wrapped_ractor)
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
          send_next_work_if_available(wrapped_ractor)
        else
          puts "Unknown message type received: #{message[:type]} from #{wrapped_ractor.name}" if ENV["FRACTOR_DEBUG"]
        end
        # Update processed count for the loop condition
        processed_count = @results.results.size + @results.errors.size
      end

      puts "Main loop finished." if ENV["FRACTOR_DEBUG"]
      return if @continuous_mode

      return unless ENV["FRACTOR_DEBUG"]

      puts "Final Aggregated Results: #{@results.inspect}"
    end

    # Stop the supervisor (for continuous mode)
    def stop
      @running = false
      puts "Stopping supervisor..." if ENV["FRACTOR_DEBUG"]
    end

    private

    # Detects the number of available processors on the system.
    # Returns the number of processors, or 2 as a fallback if detection fails.
    def detect_num_workers
      num_processors = Etc.nprocessors
      if ENV["FRACTOR_DEBUG"]
        puts "Auto-detected #{num_processors} available processors"
      end
      num_processors
    rescue StandardError => e
      if ENV["FRACTOR_DEBUG"]
        puts "Failed to detect processors: #{e.message}. Using default of 2 workers."
      end
      2
    end

    # Helper method to send the next available work item to a specific Ractor.
    def send_next_work_if_available(wrapped_ractor)
      # Ensure the wrapped_ractor instance is valid and its underlying ractor is not closed
      if wrapped_ractor && !wrapped_ractor.closed?
        if !@work_queue.empty?
          work_item = @work_queue.pop # Now directly a Work object

          puts "Sending next work #{work_item.inspect} to Ractor: #{wrapped_ractor.name}" if ENV["FRACTOR_DEBUG"]
          wrapped_ractor.send(work_item) # Send the Work object
          puts "Work sent to #{wrapped_ractor.name}." if ENV["FRACTOR_DEBUG"]
        else
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
        end
      else
        puts "Attempted to send work to an invalid or closed Ractor: #{wrapped_ractor&.name || "unknown"}." if ENV["FRACTOR_DEBUG"]
        # Remove from map if found but closed
        @ractors_map.delete(wrapped_ractor.ractor) if wrapped_ractor && @ractors_map.key?(wrapped_ractor.ractor)
      end
    end
  end
end
