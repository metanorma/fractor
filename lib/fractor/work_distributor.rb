# frozen_string_literal: true

module Fractor
  # Handles work distribution to idle workers.
  #
  # This class is responsible for distributing work items from a queue to available
  # idle workers. It ensures efficient work allocation and handles cases where no
  # workers are available.
  #
  # Extracted from Supervisor to follow Single Responsibility Principle.
  #
  # @api private
  # @see WorkDistributionManager For higher-level work distribution management
  #
  # @example Basic usage
  #   distributor = WorkDistributor.new(work_queue, worker_manager)
  #   work = Work.new("some data")
  #   distributor.distribute_work(work) # => true or false
  #
  # @example Distributing multiple items from queue
  #   distributed = distributor.distribute_queue
  #   puts "Distributed #{distributed} work items"
  class WorkDistributor
    # Initialize a new work distributor
    #
    # @param work_queue [Queue] The queue containing work items to distribute
    # @param worker_manager [Object] Manager that provides idle workers list
    # @param debug [Boolean] Enable debug logging
    def initialize(work_queue, worker_manager, debug: false)
      @work_queue = work_queue
      @worker_manager = worker_manager
      @debug = debug
    end

    # Distribute a single work item to an available idle worker
    #
    # Finds an idle worker and sends the work item to it. If no idle workers
    # are available, returns false and the work remains undistributed.
    #
    # @param work [Work] The work item to distribute
    # @return [Boolean] true if work was sent, false if no idle workers available
    #
    # @note The worker is removed from the idle workers list on success
    def distribute_work(work)
      idle_workers = @worker_manager.idle_workers

      if idle_workers.empty?
        log_debug "No idle workers available, work remains queued"
        return false
      end

      worker = idle_workers.first
      success = worker.send(work)

      if success
        log_debug "Sent work #{work.inspect} to worker #{worker.name}"
        @worker_manager.idle_workers.delete(worker)
      else
        log_debug "Failed to send work to worker #{worker.name}, marking as unavailable"
      end

      success
    end

    # Distribute work from queue to available idle workers
    #
    # Iterates through the work queue, distributing items to idle workers
    # until either the queue is empty or no idle workers remain.
    #
    # @return [Integer] Number of work items successfully distributed
    #
    # @note If distribution fails for an item, it's put back at the front of the queue
    def distribute_queue
      distributed = 0

      while !@work_queue.empty? && !@worker_manager.idle_workers.empty?
        work = @work_queue.shift
        if distribute_work(work)
          distributed += 1
        else
          # Put work back and break
          @work_queue.unshift(work)
          break
        end
      end

      distributed
    end

    # Check if there's work queued and workers available to process it
    #
    # @return [Boolean] true if both work is queued and idle workers are available
    def can_distribute?
      !@work_queue.empty? && !@worker_manager.idle_workers.empty?
    end

    # Get the number of items waiting to be distributed
    #
    # @return [Integer] Current queue size
    def queue_size
      @work_queue.size
    end

    private

    # Log debug message if debug mode is enabled
    #
    # @param message [String] Message to log
    # @return [void]
    def log_debug(message)
      puts message if @debug
    end
  end
end
