# frozen_string_literal: true

module Fractor
  # Manages the shutdown process for a Supervisor.
  # Responsible for gracefully stopping all components in the correct order.
  #
  # This class extracts shutdown logic from Supervisor to follow
  # the Single Responsibility Principle.
  class ShutdownHandler
    def initialize(workers, wakeup_ractor, timer_thread, performance_monitor,
debug: false)
      @workers = workers
      @wakeup_ractor = wakeup_ractor
      @timer_thread = timer_thread
      @performance_monitor = performance_monitor
      @debug = debug
    end

    # Execute a graceful shutdown of all supervisor components.
    # Components are stopped in the correct order to prevent issues:
    # 1. Stop performance monitor (to stop metric collection)
    # 2. Stop timer thread (to stop periodic wakeups)
    # 3. Signal wakeup ractor (to unblock Ractor.select)
    # 4. Signal all workers (to stop processing)
    #
    # @return [void]
    def shutdown
      stop_performance_monitor
      stop_timer_thread
      signal_wakeup_ractor
      signal_all_workers
    end

    # Stop the performance monitor if it's enabled.
    #
    # @return [void]
    def stop_performance_monitor
      return unless @performance_monitor

      begin
        @performance_monitor.stop
        puts "Performance monitor stopped" if @debug
      rescue StandardError => e
        puts "Error stopping performance monitor: #{e.message}" if @debug
      end
    end

    # Wait for the timer thread to finish if it exists.
    #
    # @return [void]
    def stop_timer_thread
      return unless @timer_thread

      # Only wait if thread is alive
      if @timer_thread.alive?
        @timer_thread.join(1) # Wait up to 1 second
        @timer_thread.kill # Ensure thread is stopped
        puts "Timer thread stopped" if @debug
      end
    end

    # Signal the wakeup ractor to unblock Ractor.select.
    # This is done first to allow the main loop to process the shutdown.
    #
    # @return [void]
    def signal_wakeup_ractor
      return unless @wakeup_ractor

      begin
        @wakeup_ractor.send(:shutdown)
        puts "Sent shutdown signal to wakeup ractor" if @debug
      rescue StandardError => e
        puts "Error sending shutdown to wakeup ractor: #{e.message}" if @debug
      end
    end

    # Send shutdown signal to all workers.
    # Workers should gracefully finish their current work and exit.
    #
    # @return [void]
    def signal_all_workers
      @workers.each do |w|
        begin
          w.send(:shutdown)
        rescue StandardError
          # Ignore errors when sending shutdown to workers
          nil
        end
        puts "Sent shutdown signal to #{w.name}" if @debug
      end
    end

    # Check if the shutdown process has completed.
    # This is useful for testing and monitoring.
    #
    # @return [Boolean] true if all components are stopped
    def complete?
      timer_stopped = @timer_thread.nil? || !@timer_thread.alive?
      workers_stopped = @workers.empty? || @workers.all?(&:closed?)

      timer_stopped && workers_stopped
    end

    # Get a summary of the shutdown status.
    #
    # @return [Hash] Status summary with component states
    def status_summary
      {
        performance_monitor: @performance_monitor&.send(:monitoring?) || false,
        timer_thread: @timer_thread&.alive? || false,
        wakeup_ractor: !@wakeup_ractor.nil?,
        workers_count: @workers.size,
        workers_closed: @workers.count(&:closed?),
      }
    end
  end
end
