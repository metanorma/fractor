# frozen_string_literal: true

module Fractor
  # Registry for managing work and error callbacks in Supervisor and related classes.
  # Provides a clean interface for registering and invoking callbacks with proper
  # error handling and isolation.
  class CallbackRegistry
    attr_reader :work_callbacks, :error_callbacks

    # Initialize a new callback registry.
    #
    # @param debug [Boolean] Whether to enable debug logging
    def initialize(debug: false)
      @work_callbacks = []
      @error_callbacks = []
      @debug = debug
    end

    # Register a work source callback.
    # The callback should return nil or empty array when no new work is available.
    #
    # @yield Block that returns work items or nil/empty array
    # @example
    #   registry.register_work_source do
    #     fetch_more_work_from_queue
    #   end
    def register_work_source(&block)
      @work_callbacks << block
    end

    # Register an error callback.
    # The callback receives (error_result, worker_name, worker_class).
    #
    # @yield Block that handles errors
    # @example
    #   registry.register_error_callback do |err, worker, klass|
    #     logger.error("Error in #{klass}: #{err.error}")
    #   end
    def register_error_callback(&block)
      @error_callbacks << block
    end

    # Check if there are any work callbacks registered.
    #
    # @return [Boolean] true if work callbacks exist
    def has_work_callbacks?
      !@work_callbacks.empty?
    end

    # Check if there are any error callbacks registered.
    #
    # @return [Boolean] true if error callbacks exist
    def has_error_callbacks?
      !@error_callbacks.empty?
    end

    # Process all work callbacks and return collected work items.
    # Each callback is invoked and any returned work items are collected.
    #
    # @return [Array<Work>] Array of work items from all callbacks
    def process_work_callbacks
      new_work = []
      @work_callbacks.each do |callback|
        result = callback.call
        next unless result
        next if result.empty?

        new_work.concat(Array(result))
      rescue StandardError => e
        puts "Error in work callback: #{e.message}" if @debug
      end
      new_work
    end

    # Invoke all error callbacks with the given error context.
    # Errors in callbacks are caught and logged to prevent cascading failures.
    #
    # @param error_result [WorkResult] The error result
    # @param worker_name [String] Name of the worker that encountered the error
    # @param worker_class [Class] The worker class
    def invoke_error_callbacks(error_result, worker_name, worker_class)
      @error_callbacks.each do |callback|
        callback.call(error_result, worker_name, worker_class)
      rescue StandardError => e
        puts "Error in error callback: #{e.message}" if @debug
      end
    end

    # Clear all callbacks.
    # Useful for cleanup or testing.
    def clear
      @work_callbacks.clear
      @error_callbacks.clear
    end

    # Get the total number of registered callbacks.
    #
    # @return [Hash] Hash with :work and :error callback counts
    def size
      {
        work: @work_callbacks.size,
        error: @error_callbacks.size,
      }
    end
  end
end
