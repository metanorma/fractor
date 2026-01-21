# frozen_string_literal: true

require_relative "main_loop_handler"

module Fractor
  # Ruby 3.x specific implementation of MainLoopHandler.
  # Uses Ractor.yield for worker communication.
  class MainLoopHandler3 < MainLoopHandler
    # Run the main event loop for Ruby 3.x.
    def run_loop
      loop do
        processed_count = get_processed_count

        # Check loop termination condition
        break unless should_continue_running?(processed_count)

        log_processing_status(processed_count)

        active_ractors = get_active_ractors

        # Check for new work from callbacks if in continuous mode
        process_work_callbacks if continuous_mode? && !work_callbacks.empty?

        # Handle edge cases - break if edge case handler indicates we should
        next if handle_edge_cases(active_ractors, processed_count)

        # Wait for next message from any active ractor
        ready_ractor_obj, message = select_from_ractors(active_ractors)
        next unless ready_ractor_obj && message

        # Process the received message
        process_message(ready_ractor_obj, message)
      end

      puts "Main loop finished." if @debug

      # Clean up ractors map after batch mode completion
      cleanup_ractors_map unless continuous_mode?
    end

    private

    # Get list of active ractors for Ractor.select (Ruby 3.x).
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
      # In continuous mode, if no active ractors and shutting down, exit loop
      if active_ractors.empty? && @shutting_down
        puts "No active ractors during shutdown, exiting main loop" if @debug
        return true
      end

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

    # Wait for a message from any active ractor (Ruby 3.x).
    # Uses a timeout on Windows Ruby 3.4 to detect stuck ractors.
    #
    # @param active_ractors [Array<Ractor>] List of active ractors to select from
    # @return [Array] ready_ractor_obj and message, or nil if should continue
    def select_from_ractors(active_ractors)
      # On Windows Ruby 3.4, use timeout to detect stuck ractors
      ready_ractor_obj, message = if windows_ruby_34?
                                    begin
                                      Timeout.timeout(30) do
                                        Ractor.select(*active_ractors)
                                      end
                                    rescue Timeout::Error
                                      # Timeout indicates a ractor is stuck - identify and remove it
                                      handle_stuck_ractor(active_ractors)
                                      return nil, nil
                                    end
                                  else
                                    Ractor.select(*active_ractors)
                                  end

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
  end
end
