# frozen_string_literal: true

require "fileutils"

module Fractor
  # High-level wrapper for running Fractor in continuous mode.
  # Handles threading, signal handling, and results processing automatically.
  class ContinuousServer
    attr_reader :supervisor, :work_queue

    # Initialize a continuous server
    # @param worker_pools [Array<Hash>] Worker pool configurations
    # @param work_queue [WorkQueue, nil] Optional work queue to auto-register
    # @param log_file [String, nil] Optional log file path
    def initialize(worker_pools:, work_queue: nil, log_file: nil)
      @worker_pools = worker_pools
      @work_queue = work_queue
      @log_file_path = log_file
      @log_file = nil
      @result_callbacks = []
      @error_callbacks = []
      @supervisor = nil
      @supervisor_thread = nil
      @results_thread = nil
      @running = false
    end

    # Register a callback for successful results
    # @yield [WorkResult] The successful result
    def on_result(&block)
      @result_callbacks << block
    end

    # Register a callback for errors
    # @yield [WorkResult] The error result
    def on_error(&block)
      @error_callbacks << block
    end

    # Start the server and block until shutdown
    # This method handles:
    # - Opening log file if specified
    # - Creating and starting supervisor
    # - Starting results processing thread
    # - Setting up signal handlers
    # - Blocking until shutdown signal received
    def run
      setup_log_file
      setup_supervisor
      start_supervisor_thread
      start_results_thread

      log_message("Continuous server started")
      log_message("Press Ctrl+C to stop")

      begin
        # Block until shutdown
        @supervisor_thread&.join
      rescue Interrupt
        log_message("Interrupt received, shutting down...")
      ensure
        cleanup
      end
    end

    # Stop the server programmatically
    def stop
      return unless @running

      log_message("Stopping continuous server...")
      @running = false

      @supervisor&.stop

      # Wait for threads to finish
      [@supervisor_thread, @results_thread].compact.each do |thread|
        thread.join(2) if thread.alive?
      end

      log_message("Continuous server stopped")
    end

    private

    def setup_log_file
      return unless @log_file_path

      FileUtils.mkdir_p(File.dirname(@log_file_path))
      @log_file = File.open(@log_file_path, "w")
    end

    def setup_supervisor
      @supervisor = Supervisor.new(
        worker_pools: @worker_pools,
        continuous_mode: true,
      )

      # Auto-register work queue if provided
      if @work_queue
        @work_queue.register_with_supervisor(@supervisor)
        log_message(
          "Work queue registered with supervisor (batch size: 10)",
        )
      end
    end

    def start_supervisor_thread
      @running = true
      @supervisor_thread = Thread.new do
        @supervisor.run
      rescue StandardError => e
        log_message("Supervisor error: #{e.message}")
        log_message(e.backtrace.join("\n")) if ENV["FRACTOR_DEBUG"]
      end

      # Give supervisor time to start up
      sleep(0.1)
    end

    def start_results_thread
      @results_thread = Thread.new do
        log_message("Results processing thread started")
        process_results_loop
      rescue StandardError => e
        log_message("Results thread error: #{e.message}")
        log_message(e.backtrace.join("\n")) if ENV["FRACTOR_DEBUG"]
      end
    end

    def process_results_loop
      while @running
        sleep(0.05)

        process_successful_results
        process_error_results
      end
      log_message("Results processing thread stopped")
    end

    def process_successful_results
      loop do
        result = @supervisor.results.results.shift
        break unless result

        @result_callbacks.each do |callback|
          callback.call(result)
        rescue StandardError => e
          log_message("Error in result callback: #{e.message}")
        end
      end
    end

    def process_error_results
      loop do
        error_result = @supervisor.results.errors.shift
        break unless error_result

        @error_callbacks.each do |callback|
          callback.call(error_result)
        rescue StandardError => e
          log_message("Error in error callback: #{e.message}")
        end
      end
    end

    def cleanup
      @running = false

      # Close log file if open
      if @log_file && !@log_file.closed?
        @log_file.close
        @log_file = nil
      end
    end

    def log_message(message)
      timestamp = Time.now.strftime("%Y-%m-%d %H:%M:%S.%L")
      log_entry = "[#{timestamp}] #{message}"

      if @log_file && !@log_file.closed?
        @log_file.puts(log_entry)
        @log_file.flush
      end

      puts log_entry
    end
  end
end
