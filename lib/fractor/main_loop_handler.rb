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
    end

    # Run the main event loop.
    # This method blocks until all work is processed (batch mode) or until stopped (continuous mode).
    #
    # @return [void]
    def run_loop
      loop do
        processed_count = get_processed_count

        # Check loop termination condition
        break unless should_continue_running?(processed_count)

        log_processing_status(processed_count)

        active_ractors = get_active_ractors

        # Check for new work from callbacks if in continuous mode
        process_work_callbacks if continuous_mode? && !work_callbacks.empty?

        # Handle edge cases
        handle_edge_cases(active_ractors, processed_count)

        # Wait for next message from any active ractor
        ready_ractor_obj, message = select_from_active_ractors(active_ractors)
        next unless ready_ractor_obj && message

        # Process the received message
        process_message(ready_ractor_obj, message)
      end

      puts "Main loop finished." if @debug
    end

    private

    # Get the current processed count from results.
    #
    # @return [Integer]
    def get_processed_count
      @supervisor.results.results.size + @supervisor.results.errors.size
    end

    # Check if the main loop should continue running.
    #
    # @param processed_count [Integer] Current number of processed items
    # @return [Boolean]
    def should_continue_running?(processed_count)
      running? && (continuous_mode? || processed_count < total_work_count)
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

    # Get list of active ractors for Ractor.select.
    # Excludes wakeup ractor unless in continuous mode with callbacks.
    #
    # @return [Array<Ractor>]
    def get_active_ractors
      ractors_map.keys.reject do |ractor|
        ractor == wakeup_ractor && !(continuous_mode? && !work_callbacks.empty?)
      end
    end

    # Check for new work from callbacks in continuous mode.
    #
    # @return [void]
    def process_work_callbacks
      work_callbacks.each do |callback|
        new_work = callback.call
        if new_work && !new_work.empty?
          @supervisor.add_work_items(new_work)
          puts "Work source provided #{new_work.size} new items" if @debug

          # Distribute work to idle workers
          distributed = work_distribution_manager.distribute_to_idle_workers
          puts "Distributed work to #{distributed} idle workers" if @debug && distributed.positive?
        end
      end
    end

    # Handle edge cases like no active workers or empty queue.
    #
    # @param active_ractors [Array<Ractor>] List of active ractors
    # @param processed_count [Integer] Current number of processed items
    # @return [Boolean] true if should break from loop
    def handle_edge_cases(active_ractors, processed_count)
      # Break if no active workers and queue is empty, but work remains (indicates potential issue)
      if active_ractors.empty? && work_queue.empty? && !continuous_mode? && processed_count < total_work_count
        puts "Warning: No active workers and queue is empty, but not all work is processed. Exiting loop." if @debug
        return true
      end

      # In continuous mode, just wait if no active ractors but keep running
      if active_ractors.empty?
        return true unless continuous_mode?

        sleep(0.1) # Small delay to avoid CPU spinning
        return false # Continue to next iteration
      end

      false
    end

    # Wait for a message from any active ractor.
    #
    # @param active_ractors [Array<Ractor>] List of active ractors to select from
    # @return [Array] ready_ractor_obj and message, or nil if should continue
    def select_from_active_ractors(active_ractors)
      ready_ractor_obj, message = Ractor.select(*active_ractors)

      # Check if this is the wakeup ractor
      if ready_ractor_obj == wakeup_ractor
        puts "Wakeup signal received: #{message[:message]}" if @debug
        # Remove wakeup ractor from map if shutting down
        if message[:message] == :shutdown
          ractors_map.delete(wakeup_ractor)
          @supervisor.instance_variable_set(:@wakeup_ractor, nil)
        end
        # Return nil to indicate we should continue to next iteration
        return nil, nil
      end

      [ready_ractor_obj, message]
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
      @supervisor.instance_variable_get(:@work_callbacks)
    end

    def error_callbacks
      @supervisor.instance_variable_get(:@error_callbacks)
    end
  end
end
