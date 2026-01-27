# frozen_string_literal: true

module Fractor
  # Manages the shutdown process for a Supervisor.
  # Responsible for gracefully stopping all components in the correct order.
  #
  # This class extracts shutdown logic from Supervisor to follow
  # the Single Responsibility Principle.
  class ShutdownHandler
    def initialize(workers, wakeup_ractor, timer_thread, performance_monitor,
                   main_loop_thread: nil, debug: false, continuous_mode: false)
      @workers = workers
      @wakeup_ractor = wakeup_ractor
      @timer_thread = timer_thread
      @performance_monitor = performance_monitor
      @main_loop_thread = main_loop_thread
      @debug = debug
      @continuous_mode = continuous_mode
    end

    # Execute a graceful shutdown of all supervisor components.
    # Components are stopped in the correct order to prevent issues:
    # 1. Stop performance monitor (to stop metric collection)
    # 2. Skip stopping timer thread in continuous mode (it will exit when workers close)
    # 3. Stop timer thread in batch mode (to stop periodic wakeups)
    # 4. Signal wakeup ractor (to unblock Ractor.select)
    # 5. Signal all workers (to stop processing)
    # 6. Wait for main loop thread and workers to finish
    #
    # @param wait_for_completion [Boolean] Whether to wait for all workers to close
    # @param timeout [Integer] Maximum seconds to wait for shutdown (default: 10)
    # @return [void]
    def shutdown(wait_for_completion: false, timeout: 10)
      stop_performance_monitor

      # Only stop timer thread in batch mode. In continuous mode, the timer thread
      # will exit on its own when workers are closed (it checks this condition).
      stop_timer_thread unless @continuous_mode

      signal_wakeup_ractor
      signal_all_workers

      wait_for_shutdown_completion(timeout) if wait_for_completion
    end

    # Wait for all components to finish after shutdown signals have been sent.
    # This waits for both the main loop thread (if provided) and all workers to close.
    # This is important for tests and for ensuring clean shutdown.
    #
    # @param timeout [Integer] Maximum seconds to wait
    # @return [Boolean] true if all components finished, false if timeout
    def wait_for_shutdown_completion(timeout = 10)
      start_time = Time.now
      poll_interval = 0.1

      loop do
        # Check if timeout exceeded
        break if Time.now - start_time > timeout

        # Check main loop thread status (if provided and alive)
        main_loop_done = @main_loop_thread.nil? || !@main_loop_thread.alive?

        # Check if all workers are closed
        workers_done = @workers.empty? || @workers.all?(&:closed?)

        # If both main loop and workers are done, we're finished
        if main_loop_done && workers_done
          puts "All components closed successfully" if @debug
          return true
        end

        # Show status while waiting
        if @debug
          closed_count = @workers.count(&:closed?)
          main_status = @main_loop_thread&.alive? ? "running" : "stopped"
          puts "Waiting for shutdown: main_loop=#{main_status}, workers=#{closed_count}/#{@workers.size} closed"
        end

        sleep(poll_interval)
      end

      # Timeout exceeded
      if @debug
        closed_count = @workers.count(&:closed?)
        main_status = @main_loop_thread&.alive? ? "running" : "stopped"
        puts "Shutdown timeout: main_loop=#{main_status}, workers=#{closed_count}/#{@workers.size} closed after #{timeout}s"
      end
      false
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
