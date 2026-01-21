# frozen_string_literal: true

require_relative "main_loop_handler"

module Fractor
  # Ruby 4.0+ specific implementation of MainLoopHandler.
  # Uses Ractor::Port for worker communication.
  class MainLoopHandler4 < MainLoopHandler
    # Run the main event loop for Ruby 4.0+.
    def run_loop
      # Build mapping of response ports to workers for message routing
      port_to_worker = build_port_to_worker_map

      loop do
        processed_count = get_processed_count

        # Check loop termination condition
        break unless should_continue_running?(processed_count)

        log_processing_status(processed_count)

        active_items = get_active_items

        # Check for new work from callbacks if in continuous mode
        process_work_callbacks if continuous_mode? && !work_callbacks.empty?

        # Handle edge cases - break if edge case handler indicates we should
        next if handle_edge_cases_with_ports(active_items, port_to_worker,
                                             processed_count)

        # Wait for next message from any active ractor or port
        ready_item, message = select_from_mixed(active_items, port_to_worker)
        next unless ready_item && message

        # Process the received message
        process_message_40(ready_item, message, port_to_worker)
      end

      puts "Main loop finished." if @debug

      # Clean up ractors map after batch mode completion
      cleanup_ractors_map unless continuous_mode?
    end

    # Clean up the ractors map after batch processing.
    # In Ruby 4.0, we simply clear the map to allow garbage collection.
    # The main loop already attempted to shut down workers properly.
    #
    # @return [void]
    def cleanup_ractors_map
      return if ractors_map.empty?

      puts "Cleaning up ractors map (#{ractors_map.size} entries)..." if @debug

      # Simply clear the map without trying to interact with ractors
      # The main loop already attempted to shut down workers properly
      ractors_map.clear

      # Force garbage collection to help clean up orphaned ractors
      GC.start
      puts "Ractors map cleared and GC forced." if @debug
    end

    private

    # Build mapping of response ports to workers.
    # This is needed to route messages from ports back to workers.
    #
    # @return [Hash] Mapping of Ractor::Port => WrappedRactor
    def build_port_to_worker_map
      port_map = {}
      ractors_map.each_value do |wrapped_ractor|
        next unless wrapped_ractor.is_a?(WrappedRactor4)

        port = wrapped_ractor.response_port
        port_map[port] = wrapped_ractor if port
      end
      port_map
    end

    # Get list of active items for Ractor.select (Ruby 4.0+).
    # Includes both response ports and ractors (excluding wakeup ractor).
    #
    # @return [Array] List of Ractor::Port and Ractor objects
    def get_active_items
      items = []

      # Add response ports from all workers
      ractors_map.each_value do |wrapped_ractor|
        next unless wrapped_ractor.is_a?(WrappedRactor4)

        port = wrapped_ractor.response_port
        items << port if port
      end

      # Add wakeup ractor/port if in continuous mode with callbacks
      if continuous_mode? && !work_callbacks.empty? && wakeup_ractor && wakeup_port
        items << wakeup_port
      end

      items
    end

    # Get list of active ractors for compatibility with Ruby 3.x tests.
    # In Ruby 4.0, returns the actual ractor objects (not ports).
    #
    # @return [Array<Ractor>] List of active Ractor objects
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
    # Overload for compatibility with tests (2-argument version).
    #
    # @param active_ractors [Array<Ractor>] List of active ractors
    # @param processed_count [Integer] Current number of processed items
    # @return [Boolean] true if should break from loop
    def handle_edge_cases(active_ractors, processed_count)
      # For Ruby 4.0 compatibility with tests:
      # Use the active_ractors array directly since tests pass it in
      # In normal operation, this would be derived from ractors_map

      # In continuous mode, if no active ractors and shutting down, exit loop
      if active_ractors.empty? && @shutting_down
        puts "No active ractors during shutdown, exiting main loop" if @debug
        return true
      end

      # Break if no active ractors and queue is empty, but work remains
      if active_ractors.empty? && work_queue.empty? && !continuous_mode? && processed_count < total_work_count
        puts "Warning: No active ractors and queue is empty, but not all work is processed. Exiting loop." if @debug
        return true
      end

      # In continuous mode, just wait if no active ractors but keep running
      if active_ractors.empty?
        return true unless continuous_mode?

        sleep(0.1) # Small delay to avoid CPU spinning
        return false # Continue to next iteration
      end

      false # There are active ractors, continue the loop
    end

    # Handle edge cases like no active workers or empty queue (3-argument version).
    #
    # @param _active_items [Array] List of active ports/ractors
    # @param port_to_worker [Hash] Mapping of ports to workers
    # @param processed_count [Integer] Current number of processed items
    # @return [Boolean] true if should break from loop
    def handle_edge_cases_with_ports(_active_items, port_to_worker,
processed_count)
      # Count active workers (those with response ports)
      active_worker_count = port_to_worker.size

      # In continuous mode, if no active workers and shutting down, exit loop
      if active_worker_count.zero? && @shutting_down
        puts "No active workers during shutdown, exiting main loop" if @debug
        return true
      end

      # Break if no active workers and queue is empty, but work remains
      if active_worker_count.zero? && work_queue.empty? && !continuous_mode? && processed_count < total_work_count
        puts "Warning: No active workers and queue is empty, but not all work is processed. Exiting loop." if @debug
        return true
      end

      # In continuous mode, just wait if no active workers but keep running
      if active_worker_count.zero?
        return true unless continuous_mode?

        sleep(0.1) # Small delay to avoid CPU spinning
        return false # Continue to next iteration
      end

      false
    end

    # Wait for a message from any active ractor or port (Ruby 4.0+).
    # In Ruby 4.0, we select from a mix of response ports and ractors.
    #
    # @param active_items [Array] List of active ports/ractors
    # @param port_to_worker [Hash] Mapping of ports to workers
    # @return [Array] ready_item and message, or nil if should continue
    def select_from_mixed(active_items, port_to_worker)
      # In Ruby 4.0, we use Ractor.select on ports (and potentially ractors)
      # The response ports receive :result and :error messages
      # The wakeup ractor (if present) receives wakeup signals

      return nil, nil if active_items.empty?

      ready_item, message = Ractor.select(*active_items)

      # Check if this is the wakeup port
      if ready_item == wakeup_port
        puts "Wakeup signal received: #{message[:message]}" if @debug
        # Remove wakeup ractor from map if shutting down
        if message && message[:message] == :shutdown
          ractors_map.delete(wakeup_ractor)
          @supervisor.instance_variable_set(:@wakeup_ractor, nil)
        end
        # Return nil to indicate we should continue to next iteration
        return nil, nil
      end

      [ready_item, message]
    rescue Ractor::ClosedError, Ractor::Error => e
      # Handle closed ports/ractors - remove them from ractors_map
      puts "Ractor::Error in select: #{e.message}. Cleaning up closed ports." if @debug

      # Find and remove workers with closed ports
      closed_ports = active_items.select { |item| item.is_a?(Ractor::Port) }
      closed_ports.each do |port|
        wrapped_ractor = port_to_worker[port]
        if wrapped_ractor
          puts "Removing worker with closed port: #{wrapped_ractor.name}" if @debug
          ractors_map.delete(wrapped_ractor.ractor)
          workers.delete(wrapped_ractor)
          port_to_worker.delete(port)
        end
      end

      # Return nil to continue the loop with updated active_items
      [nil, nil]
    end

    # Process a message from a ractor or port (Ruby 4.0+).
    # Most messages come through response ports in Ruby 4.0.
    #
    # @param ready_item [Ractor::Port, Ractor] The port or ractor that sent the message
    # @param message [Hash] The message received
    # @param port_to_worker [Hash] Mapping of ports to workers
    # @return [void]
    def process_message_40(ready_item, message, port_to_worker)
      # Find the corresponding WrappedRactor instance
      if ready_item.is_a?(Ractor::Port)
        # Message from a response port - look up worker
        wrapped_ractor = port_to_worker[ready_item]
        unless wrapped_ractor
          puts "Warning: Received message from unknown port: #{ready_item}. Ignoring." if @debug
          return
        end
      else
        # Message from a ractor (e.g., initialize, shutdown acknowledgment)
        wrapped_ractor = ractors_map[ready_item]
        unless wrapped_ractor
          puts "Warning: Received message from unknown Ractor: #{ready_item}. Ignoring." if @debug
          ractors_map.delete(ready_item)
          return
        end
      end

      # Guard against nil messages (indicates closed port/ractor)
      if message.nil?
        puts "Warning: Received nil message from #{wrapped_ractor.name}. Port/Ractor likely closed." if @debug
        ractors_map.delete(wrapped_ractor.ractor)
        workers.delete(wrapped_ractor)
        port_to_worker.delete(ready_item) if ready_item.is_a?(Ractor::Port)
        return
      end

      puts "Selected from: #{wrapped_ractor.name}, Message Type: #{message[:type]}" if @debug

      # Route to appropriate message handler
      case message[:type]
      when :initialize
        handle_initialize_message(wrapped_ractor)
      when :shutdown
        handle_shutdown_message(wrapped_ractor.ractor, wrapped_ractor)
      when :result
        handle_result_message(wrapped_ractor, message)
      when :error
        handle_error_message(wrapped_ractor, message)
      else
        puts "Unknown message type received: #{message[:type]} from #{wrapped_ractor.name}" if @debug
      end
    end
  end
end
