# frozen_string_literal: true

module Fractor
  # Handles the main event loop for a Supervisor.
  # Responsible for processing Ractor messages and coordinating work distribution.
  #
  # This class extracts the main loop logic from Supervisor to follow
  # the Single Responsibility Principle.
  class MainLoopHandler
    def initialize(supervisor, debug: false)
      @supervisor = supervisor
      @debug = debug
      @shutting_down = false
    end

    # Factory method to create the appropriate MainLoopHandler implementation
    # based on the current Ruby version.
    #
    # @param supervisor [Fractor::Supervisor] The supervisor instance
    # @param debug [Boolean] Whether debug mode is enabled
    # @return [MainLoopHandler] The appropriate subclass instance
    def self.create(supervisor, debug: false)
      if Fractor::RUBY_4_0_OR_HIGHER
        MainLoopHandler4.new(supervisor, debug: debug)
      else
        MainLoopHandler3.new(supervisor, debug: debug)
      end
    end

    # Run the main event loop.
    # This method blocks until all work is processed (batch mode) or until stopped (continuous mode).
    #
    # @return [void]
    def run_loop
      raise NotImplementedError, "Subclasses must implement #run_loop"
    end

    # Clean up the ractors map after batch processing.
    # This is critical on Windows Ruby 3.4 where workers may not respond to shutdown
    # if they're stuck in Ractor.receive.
    #
    # @return [void]
    def cleanup_ractors_map
      return if ractors_map.empty?

      puts "Cleaning up ractors map (#{ractors_map.size} entries)..." if @debug

      # Simply clear the map without trying to interact with ractors
      # The main loop already attempted to shut down workers properly
      # On Windows Ruby 3.4, some workers may be stuck in Ractor.receive
      # and will never acknowledge shutdown - we must not block on them
      ractors_map.clear

      # Force garbage collection to help clean up orphaned ractors
      # This is a workaround for Ruby 3.4 Windows where orphaned ractors
      # can block creation of new ractors in subsequent tests
      GC.start
      puts "Ractors map cleared and GC forced." if @debug
    end

    # Initiate graceful shutdown.
    # Sets the shutting_down flag to allow the main loop to process
    # shutdown acknowledgments before exiting.
    #
    # @return [void]
    def initiate_shutdown
      @shutting_down = true
      puts "Main loop shutdown initiated" if @debug
    end

    private

    # Get the current processed count from results.
    #
    # @return [Integer]
    def get_processed_count
      @supervisor.results.results.size + @supervisor.results.errors.size
    end

    # Check if the main loop should continue running.
    # Continues during shutdown until all workers have acknowledged.
    #
    # @param processed_count [Integer] Current number of processed items
    # @return [Boolean]
    def should_continue_running?(processed_count)
      return true if @shutting_down && !all_workers_closed?

      running? && (continuous_mode? || processed_count < total_work_count)
    end

    # Check if all workers have closed (acknowledged shutdown).
    #
    # @return [Boolean]
    def all_workers_closed?
      workers.all?(&:closed?)
    end

    # Log current processing status for debugging.
    #
    # @param processed_count [Integer] Current number of processed items
    # @return [void]
    def log_processing_status(processed_count)
      return unless @debug

      if continuous_mode?
        puts "Continuous mode: Waiting for Ractor results. Processed: #{processed_count}, Queue size: #{work_queue.size}"
      else
        puts "Waiting for Ractor results. Processed: #{processed_count}/#{total_work_count}, Queue size: #{work_queue.size}"
      end
    end

    # Process a message from a ractor.
    #
    # @param ready_ractor_obj [Ractor] The ractor that sent the message
    # @param message [Hash] The message received
    # @return [void]
    def process_message(ready_ractor_obj, message)
      # Find the corresponding WrappedRactor instance
      wrapped_ractor = ractors_map[ready_ractor_obj]
      unless wrapped_ractor
        puts "Warning: Received message from unknown Ractor: #{ready_ractor_obj}. Ignoring." if @debug
        ractors_map.delete(ready_ractor_obj)
        return
      end

      # Guard against nil messages (indicates closed ractor)
      if message.nil?
        puts "Warning: Received nil message from #{wrapped_ractor.name}. Ractor likely closed." if @debug
        ractors_map.delete(ready_ractor_obj)
        workers.delete(wrapped_ractor)
        return
      end

      puts "Selected Ractor: #{wrapped_ractor.name}, Message Type: #{message[:type]}" if @debug

      # Route to appropriate message handler
      case message[:type]
      when :initialize
        handle_initialize_message(wrapped_ractor)
      when :shutdown
        handle_shutdown_message(ready_ractor_obj, wrapped_ractor)
      when :result
        handle_result_message(wrapped_ractor, message)
      when :error
        handle_error_message(wrapped_ractor, message)
      else
        puts "Unknown message type received: #{message[:type]} from #{wrapped_ractor.name}" if @debug
      end
    end

    # Handle :initialize message from a worker.
    #
    # @param wrapped_ractor [WrappedRactor] The worker ractor
    # @return [void]
    def handle_initialize_message(wrapped_ractor)
      puts "Ractor initialized: #{wrapped_ractor.worker_class}" if @debug

      if work_distribution_manager.assign_work_to_worker(wrapped_ractor)
        # Work was sent
      elsif continuous_mode?
        work_distribution_manager.mark_worker_idle(wrapped_ractor)
        puts "Worker #{wrapped_ractor.name} marked as idle (continuous mode)" if @debug
      else
        handle_batch_mode_no_work(wrapped_ractor)
      end
    end

    # Handle :shutdown message from a worker.
    #
    # @param ready_ractor_obj [Ractor] The ractor object
    # @param wrapped_ractor [WrappedRactor] The worker ractor
    # @return [void]
    def handle_shutdown_message(ready_ractor_obj, wrapped_ractor)
      puts "Ractor #{wrapped_ractor.name} acknowledged shutdown" if @debug
      ractors_map.delete(ready_ractor_obj)
    end

    # Handle :result message from a worker.
    #
    # @param wrapped_ractor [WrappedRactor] The worker ractor
    # @param message [Hash] The message containing the result
    # @return [void]
    def handle_result_message(wrapped_ractor, message)
      work_result = message[:result]
      puts "Completed work: #{work_result.inspect} in Ractor: #{message[:processor]}" if @debug

      # Record performance metrics
      record_performance_metrics(work_result, success: true)

      # Trace work item completed
      @supervisor.send(:trace_work, :completed, work_result.work,
                       worker_name: wrapped_ractor.name,
                       worker_class: wrapped_ractor.worker_class)

      # Record result to error reporter
      error_reporter.record(work_result,
                            job_name: wrapped_ractor.worker_class.name)

      results.add_result(work_result)

      if @debug
        puts "Result processed. Total processed: #{results.results.size + results.errors.size}"
        puts "Aggregated Results: #{results.inspect}" unless continuous_mode?
      end

      # Send next piece of work
      assign_next_work_or_shutdown(wrapped_ractor)
    end

    # Handle :error message from a worker.
    #
    # @param wrapped_ractor [WrappedRactor] The worker ractor
    # @param message [Hash] The message containing the error
    # @return [void]
    def handle_error_message(wrapped_ractor, message)
      error_result = message[:result]

      # Record performance metrics
      record_performance_metrics(error_result, success: false)

      # Trace work item failed
      @supervisor.send(:trace_work, :failed, error_result.work,
                       worker_name: wrapped_ractor.name,
                       worker_class: wrapped_ractor.worker_class)

      # Record error to error reporter
      error_reporter.record(error_result,
                            job_name: wrapped_ractor.worker_class.name)

      # Invoke error callbacks
      error_callbacks.each do |callback|
        callback.call(error_result, wrapped_ractor.name,
                      wrapped_ractor.worker_class)
      rescue StandardError => e
        puts "Error in error callback: #{e.message}" if @debug
      end

      # Enhanced error message with context
      error_context = @supervisor.send(:format_error_context, wrapped_ractor,
                                       error_result)
      puts error_context if @debug

      results.add_result(error_result)

      if @debug
        puts "Error handled. Total processed: #{results.results.size + results.errors.size}"
        puts "Aggregated Results (including errors): #{results.inspect}" unless continuous_mode?
      end

      # Send next piece of work even after an error
      assign_next_work_or_shutdown(wrapped_ractor)
    end

    # Record performance metrics for a completed job.
    #
    # @param work_result [WorkResult] The result object
    # @param success [Boolean] Whether the job succeeded
    # @return [void]
    def record_performance_metrics(work_result, success:)
      return unless performance_monitor && work_result.work

      start_time = work_distribution_manager.get_work_start_time(work_result.work.object_id)
      return unless start_time

      latency = Time.now - start_time
      performance_monitor.record_job(latency, success: success)
    end

    # Handle batch mode when no work is available.
    #
    # @param wrapped_ractor [WrappedRactor] The worker ractor
    # @return [void]
    def handle_batch_mode_no_work(wrapped_ractor)
      current_processed = results.results.size + results.errors.size
      if current_processed >= total_work_count
        puts "All work processed, shutting down worker #{wrapped_ractor.name} (batch mode)" if @debug
        wrapped_ractor.send(:shutdown)
      else
        # Work still pending but queue empty - shouldn't happen in normal flow
        # Keep worker alive and add to idle list
        work_distribution_manager.mark_worker_idle(wrapped_ractor)
        puts "Worker #{wrapped_ractor.name} marked as idle (queue empty but work pending: #{current_processed}/#{total_work_count})" if @debug
      end
    end

    # Assign next work to worker or shut down if all work is done.
    #
    # @param wrapped_ractor [WrappedRactor] The worker ractor
    # @return [void]
    def assign_next_work_or_shutdown(wrapped_ractor)
      if work_distribution_manager.assign_work_to_worker(wrapped_ractor)
        # Work was sent
      elsif continuous_mode?
        work_distribution_manager.mark_worker_idle(wrapped_ractor)
        puts "Worker #{wrapped_ractor.name} marked as idle after completing work (continuous mode)" if @debug
      else
        handle_batch_mode_no_work(wrapped_ractor)
      end
    end

    # Helper methods to access supervisor state

    def running?
      @supervisor.instance_variable_get(:@running)
    end

    def continuous_mode?
      @supervisor.instance_variable_get(:@continuous_mode)
    end

    def total_work_count
      @supervisor.instance_variable_get(:@total_work_count)
    end

    def work_queue
      @supervisor.work_queue
    end

    def workers
      @supervisor.workers
    end

    def ractors_map
      @supervisor.instance_variable_get(:@ractors_map)
    end

    def wakeup_ractor
      @supervisor.instance_variable_get(:@wakeup_ractor)
    end

    def wakeup_port
      @supervisor.instance_variable_get(:@wakeup_port)
    end

    def work_distribution_manager
      @supervisor.instance_variable_get(:@work_distribution_manager)
    end

    def results
      @supervisor.results
    end

    def error_reporter
      @supervisor.error_reporter
    end

    def performance_monitor
      @supervisor.instance_variable_get(:@performance_monitor)
    end

    def work_callbacks
      @supervisor.callback_registry.work_callbacks
    end

    def error_callbacks
      @supervisor.callback_registry.error_callbacks
    end

    # Check if running on Windows with Ruby 3.4
    # Returns true for Windows Ruby 3.4.x where Ractor issues occur
    #
    # @return [Boolean]
    def windows_ruby_34?
      Fractor::WINDOWS_RUBY_34
    end

    # Handle a stuck ractor by identifying and removing it from the active pool
    # This is called when Ractor.select times out on Windows Ruby 3.4
    #
    # @param active [Array] List of active ractors/ports
    # @return [void]
    def handle_stuck_ractor(active)
      puts "[WARNING] Ractor.select timeout - detecting stuck ractor..." if @debug

      # Try to identify which ractor is stuck by checking their state
      active.each do |ractor_or_port|
        # Skip ports (Ruby 4.0) - they should be checked differently
        next if ractor_or_port.is_a?(Ractor::Port)

        wrapped_ractor = ractors_map[ractor_or_port]
        next unless wrapped_ractor

        # Check if ractor appears stuck (terminated or blocked)
        begin
          inspect_result = Timeout.timeout(0.1) { ractor_or_port.inspect }
        rescue Timeout::Error
          inspect_result = "#<Ractor:blocked>"
        end

        if inspect_result.include?("terminated") || inspect_result.include?("invalid")
          puts "[WARNING] Removing stuck/terminated ractor: #{wrapped_ractor.name}" if @debug
          ractors_map.delete(ractor_or_port)
          workers.delete(wrapped_ractor)
        end
      end

      # Force garbage collection to help clean up stuck ractors
      GC.start
      puts "[WARNING] Stuck ractor handled, GC forced" if @debug
    end
  end
end
