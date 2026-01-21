# frozen_string_literal: true

module Fractor
  # Manages work distribution to workers in a Supervisor.
  # Responsible for tracking idle workers and assigning work from the queue.
  #
  # This class extracts work distribution logic from Supervisor to follow
  # the Single Responsibility Principle.
  class WorkDistributionManager
    attr_reader :idle_workers

    def initialize(work_queue, workers, ractors_map, debug: false,
                   continuous_mode: false, performance_monitor: nil)
      @work_queue = work_queue
      @workers = workers
      @ractors_map = ractors_map
      @debug = debug
      @continuous_mode = continuous_mode
      @performance_monitor = performance_monitor
      @idle_workers = []
      @work_start_times = {}
    end

    # Update the workers reference after workers are created
    # This is needed when @workers is reassigned in Supervisor.start_workers
    #
    # @param workers [Array<WrappedRactor>] The new workers array
    def update_workers(workers)
      @workers = workers
    end

    # Assign work to a specific worker if work is available.
    #
    # @param wrapped_ractor [WrappedRactor] The worker to assign work to
    # @return [Boolean] true if work was sent, false otherwise
    def assign_work_to_worker(wrapped_ractor)
      # Ensure the wrapped_ractor instance is valid and its underlying ractor is not closed
      if wrapped_ractor && !wrapped_ractor.closed?
        if @work_queue.empty?
          puts "Work queue empty. Not sending new work to Ractor #{wrapped_ractor.name}." if @debug
          false
        else
          work_item = @work_queue.pop # Now directly a Work object

          # Track start time for performance monitoring
          if @performance_monitor
            @work_start_times[work_item.object_id] = Time.now
          end

          puts "Sending next work #{work_item.inspect} to Ractor: #{wrapped_ractor.name}." if @debug
          wrapped_ractor.send(work_item) # Send the Work object
          puts "Work sent to #{wrapped_ractor.name}." if @debug

          # Remove from idle workers list since it's now busy
          @idle_workers.delete(wrapped_ractor)
          true
        end
      else
        puts "Attempted to send work to an invalid or closed Ractor: #{wrapped_ractor&.name || 'unknown'}." if @debug
        # Remove from map if found but closed
        if wrapped_ractor && @ractors_map.key?(wrapped_ractor.ractor)
          @ractors_map.delete(wrapped_ractor.ractor)
        end
        false
      end
    end

    # Mark a worker as idle (available for work).
    #
    # @param wrapped_ractor [WrappedRactor] The worker to mark as idle
    def mark_worker_idle(wrapped_ractor)
      @idle_workers << wrapped_ractor unless @idle_workers.include?(wrapped_ractor)
      puts "Worker #{wrapped_ractor.name} marked as idle." if @debug
    end

    # Mark a worker as busy (not available for work).
    #
    # @param wrapped_ractor [WrappedRactor] The worker to mark as busy
    def mark_worker_busy(wrapped_ractor)
      @idle_workers.delete(wrapped_ractor)
    end

    # Distribute available work to idle workers.
    # Useful when new work is added to the queue.
    #
    # @return [Integer] Number of workers that received work
    def distribute_to_idle_workers
      distributed = 0
      while !@work_queue.empty? && !@idle_workers.empty?
        worker = @idle_workers.shift
        if assign_work_to_worker(worker)
          puts "Sent work to idle worker #{worker.name}" if @debug
          distributed += 1
        end
      end
      distributed
    end

    # Get the list of idle (available) workers.
    #
    # @return [Array<WrappedRactor>] List of idle workers
    def idle_workers_list
      @idle_workers.dup
    end

    # Get the list of busy (processing) workers.
    #
    # @return [Array<WrappedRactor>] List of busy workers
    def busy_workers_list
      @workers.reject { |w| @idle_workers.include?(w) }
    end

    # Get the count of idle workers.
    #
    # @return [Integer] Number of idle workers
    def idle_count
      @idle_workers.size
    end

    # Get the count of busy workers.
    #
    # @return [Integer] Number of busy workers
    def busy_count
      @workers.size - @idle_workers.size
    end

    # Get the work start time for a specific work item.
    #
    # @param work_object_id [Integer] The object_id of the work item
    # @return [Time, nil] The start time, or nil if not found
    def get_work_start_time(work_object_id)
      @work_start_times.delete(work_object_id)
    end

    # Clear all tracked work start times.
    # Useful for cleanup or testing.
    def clear_work_start_times
      @work_start_times.clear
    end

    # Get current worker status summary.
    #
    # @return [Hash] Worker status summary with :idle and :busy counts
    def status_summary
      {
        idle: @idle_workers.size,
        busy: @workers.size - @idle_workers.size,
      }
    end
  end
end
