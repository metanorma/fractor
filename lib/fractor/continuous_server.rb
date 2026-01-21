# frozen_string_literal: true

require "fileutils"

module Fractor
  # High-level wrapper for running Fractor in continuous mode.
  # Handles threading, signal handling, and results processing automatically.
  class ContinuousServer
    attr_reader :supervisor, :work_queue, :logger

    # Initialize a continuous server
    # @param worker_pools [Array<Hash>] Worker pool configurations
    # @param work_queue [WorkQueue, nil] Optional work queue to auto-register
    # @param log_file [String, nil] Optional log file path
    # @param logger [Logger, nil] Optional logger instance for isolation (defaults to Fractor.logger)
    def initialize(worker_pools:, work_queue: nil, log_file: nil, logger: nil)
      @worker_pools = worker_pools
      @work_queue = work_queue
      @log_file_path = log_file
      @log_file = nil
      @logger = logger # Store instance-specific logger for isolation
      @result_callbacks = []
      @error_callbacks = []
      @supervisor = nil
      @supervisor_thread = nil
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

    # Start the server (alias for run).
    # Provides a consistent API with stop method.
    #
    # @see #run
    def start
      run
    end

    # Start the server and block until shutdown
    # This method handles:
    # - Opening log file if specified
    # - Creating and starting supervisor
    # - Registering result callbacks with ResultAggregator
    # - Blocking until shutdown signal received
    def run
      setup_log_file
      setup_supervisor
      register_result_callbacks
      start_supervisor_thread

      log_message("Continuous server started")
      log_message("Press Ctrl+C to stop")

      begin
        # Event-driven: simply join the supervisor thread
        # It will exit when @running = false and shutdown is complete
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

      # Ensure log file is closed
      # This is important when stop() is called from outside the run() thread
      # The run() method's ensure block will also call cleanup, but we ensure
      # it here as well for immediate cleanup
      cleanup
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
        logger: @logger, # Pass instance-specific logger for isolation
      )

      # Auto-register work queue if provided
      if @work_queue
        @work_queue.register_with_supervisor(@supervisor)
        log_message(
          "Work queue registered with supervisor (batch size: 10)",
        )
      end
    end

    def register_result_callbacks
      # Register callbacks directly with ResultAggregator for event-driven processing
      # This eliminates the need for a separate results polling thread
      unless @result_callbacks.empty?
        @supervisor.results.on_new_result do |result|
          if result.success?
            @result_callbacks.each do |callback|
              callback.call(result)
            rescue StandardError => e
              log_message("Error in result callback: #{e.message}")
            end
          end
        end
      end

      unless @error_callbacks.empty?
        @supervisor.results.on_new_result do |result|
          unless result.success?
            @error_callbacks.each do |callback|
              callback.call(result)
            rescue StandardError => e
              log_message("Error in error callback: #{e.message}")
            end
          end
        end
      end
    end

    def start_supervisor_thread
      @running = true
      @supervisor_thread = Thread.new do
        @supervisor.run
      rescue StandardError => e
        log_message("Supervisor error: #{e.message}")
        # Use instance logger or fall back to global
        instance_logger = @logger || Fractor.logger
        instance_logger.debug(e.backtrace.join("\n")) if instance_logger&.debug?
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
        begin
          @log_file.puts(log_entry)
          @log_file.flush
        rescue IOError
          # File was closed in another thread, stop trying to write to it
          @log_file = nil
        end
      end

      puts log_entry
    end
  end
end
