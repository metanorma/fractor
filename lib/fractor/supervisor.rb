# frozen_string_literal: true

module Fractor
  # Supervises multiple WrappedRactors, distributes work, and aggregates results.
  class Supervisor
    attr_reader :work_queue, :workers, :results, :worker_class, :work_class

    # Initializes the Supervisor.
    # - worker_class: The class inheriting from Fractor::Worker (e.g., MyWorker).
    # - work_class: The class inheriting from Fractor::Work (e.g., MyWork). Can be nil for mixed work types.
    # - num_workers: The number of Ractors to spawn.
    # - continuous_mode: Whether to run in continuous mode without expecting a fixed work count.
    def initialize(worker_class:, work_class:, num_workers: 2, continuous_mode: false)
      raise ArgumentError, "#{worker_class} must inherit from Fractor::Worker" unless worker_class < Fractor::Worker
      raise ArgumentError, "#{work_class} must inherit from Fractor::Work or be nil" unless work_class.nil? || work_class < Fractor::Work

      @worker_class = worker_class
      @work_class = work_class
      @work_queue = Queue.new
      @results = ResultAggregator.new
      @num_workers = num_workers
      @workers = []
      @total_work_count = 0 # Track total items initially added
      @ractors_map = {} # Map Ractor object to WrappedRactor instance
      @continuous_mode = continuous_mode
      @running = false
      @work_callbacks = []
    end

    # Adds work items to the queue.
    # Items should be the raw input data, not Work objects yet.
    # For mixed work types, provide specific_work_class to override the default.
    def add_work(items, specific_work_class = nil)
      work_class_to_use = specific_work_class || @work_class

      raise ArgumentError, "#{work_class_to_use} must inherit from Fractor::Work or be nil" unless work_class_to_use.nil? || work_class_to_use < Fractor::Work

      items.each do |item|
        @work_queue << { data: item, work_class: work_class_to_use }
      end

      @total_work_count += items.size
      puts "Work added. Initial work count: #{@total_work_count}, Queue size: #{@work_queue.size}"
    end

    # Register a callback to provide new work items
    # The callback should return nil or empty array when no new work is available
    def register_work_source(&callback)
      @work_callbacks << callback
    end

    # Starts the worker Ractors.
    def start_workers
      @workers = (1..@num_workers).map do |i|
        # Pass the client's worker class (e.g., MyWorker) to WrappedRactor
        wrapped_ractor = WrappedRactor.new("worker #{i}", @worker_class)
        wrapped_ractor.start # Start the underlying Ractor
        # Map the actual Ractor object to the WrappedRactor instance
        @ractors_map[wrapped_ractor.ractor] = wrapped_ractor if wrapped_ractor.ractor
        wrapped_ractor
      end
      # Filter out any workers that failed to start properly
      @workers.compact!
      @ractors_map.compact! # Ensure map doesn't contain nil keys/values
      puts "Workers started: #{@workers.size} active."
    end

    # Sets up a signal handler for graceful shutdown (Ctrl+C).
    def setup_signal_handler
      # Need access to @workers within the trap block
      workers_ref = @workers
      Signal.trap("INT") do
        puts "\nCtrl+C received. Initiating immediate shutdown..."
        puts "Attempting to close worker Ractors..."
        workers_ref.each do |w|
          w.close # Use the close method of WrappedRactor
          puts "Closed Ractor: #{w.name}"
        rescue StandardError => e
          puts "Error closing Ractor #{w.name}: #{e.message}"
        end
        puts "Exiting now."
        exit(1) # Exit immediately
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

        if @continuous_mode
          puts "Continuous mode: Waiting for Ractor results. Processed: #{processed_count}, Queue size: #{@work_queue.size}"
        else
          puts "Waiting for Ractor results. Processed: #{processed_count}/#{@total_work_count}, Queue size: #{@work_queue.size}"
        end

        # Get active Ractor objects from the map keys
        active_ractors = @ractors_map.keys

        # Check for new work from callbacks if in continuous mode and queue is empty
        if @continuous_mode && @work_queue.empty? && !@work_callbacks.empty?
          @work_callbacks.each do |callback|
            new_work = callback.call
            add_work(new_work) if new_work && !new_work.empty?
          end
        end

        # Break if no active workers and queue is empty, but work remains (indicates potential issue)
        if active_ractors.empty? && @work_queue.empty? && !@continuous_mode && processed_count < @total_work_count
          puts "Warning: No active workers and queue is empty, but not all work is processed. Exiting loop."
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
          puts "Warning: Received message from unknown Ractor: #{ready_ractor_obj}. Ignoring."
          next
        end

        puts "Selected Ractor: #{wrapped_ractor.name}, Message Type: #{message[:type]}"

        # Process the received message
        case message[:type]
        when :initialize
          puts "Ractor initialized: #{message[:processor]}"
          # Send work immediately upon initialization if available
          send_next_work_if_available(wrapped_ractor)
        when :result
          # The message[:result] should be a WorkResult object
          work_result = message[:result]
          puts "Completed work: #{work_result.inspect} in Ractor: #{message[:processor]}"
          @results.add_result(work_result)
          puts "Result processed. Total processed: #{@results.results.size + @results.errors.size}"
          puts "Aggregated Results: #{@results.inspect}" unless @continuous_mode
          # Send next piece of work
          send_next_work_if_available(wrapped_ractor)
        when :error
          # The message[:result] should be a WorkResult object containing the error
          error_result = message[:result]
          puts "Error processing work #{error_result.work&.inspect} in Ractor: #{message[:processor]}: #{error_result.error}"
          @results.add_result(error_result) # Add error to aggregator
          puts "Error handled. Total processed: #{@results.results.size + @results.errors.size}"
          puts "Aggregated Results (including errors): #{@results.inspect}" unless @continuous_mode
          # Send next piece of work even after an error
          send_next_work_if_available(wrapped_ractor)
        else
          puts "Unknown message type received: #{message[:type]} from #{wrapped_ractor.name}"
        end
        # Update processed count for the loop condition
        processed_count = @results.results.size + @results.errors.size
      end

      puts "Main loop finished."
      return if @continuous_mode

      puts "Final Aggregated Results: #{@results.inspect}"
    end

    # Stop the supervisor (for continuous mode)
    def stop
      @running = false
      puts "Stopping supervisor..."
    end

    private

    # Helper method to send the next available work item to a specific Ractor.
    def send_next_work_if_available(wrapped_ractor)
      # Ensure the wrapped_ractor instance is valid and its underlying ractor is not closed
      if wrapped_ractor && !wrapped_ractor.closed?
        if !@work_queue.empty?
          work_info = @work_queue.pop # Get work info (data and class)

          # Get the work class from the queue item or use the default
          work_class = work_info[:work_class] || @work_class

          if work_class.nil?
            puts "Error: Work class is nil and no specific work class provided for item: #{work_info[:data]}"
            # Create a generic error result
            error_result = Fractor::WorkResult.new(
              error: "No work class specified for item",
              work: nil
            )
            @results.add_result(error_result)
            return
          end

          # Create an instance of the appropriate Work class
          work_item = work_class.new(work_info[:data])
          puts "Sending next work #{work_item.inspect} to Ractor: #{wrapped_ractor.name}"
          wrapped_ractor.send(work_item) # Send the Work object
          puts "Work sent to #{wrapped_ractor.name}."
        else
          puts "Work queue empty. Not sending new work to Ractor #{wrapped_ractor.name}."
          # In continuous mode, don't close workers as more work may come
          unless @continuous_mode
            # Consider closing the Ractor if the queue is empty and no more work is expected.
            # wrapped_ractor.close
            # @ractors_map.delete(wrapped_ractor.ractor)
            # puts "Closed idle Ractor: #{wrapped_ractor.name}"
          end
        end
      else
        puts "Attempted to send work to an invalid or closed Ractor: #{wrapped_ractor&.name || "unknown"}."
        # Remove from map if found but closed
        @ractors_map.delete(wrapped_ractor.ractor) if wrapped_ractor && @ractors_map.key?(wrapped_ractor.ractor)
      end
    end
  end
end
