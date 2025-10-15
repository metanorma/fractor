# frozen_string_literal: true

module Fractor
  # Thread-safe work queue for continuous mode applications.
  # Provides a simple interface for adding work items and retrieving them
  # in batches, with automatic integration with Fractor::Supervisor.
  class WorkQueue
    attr_reader :queue

    def initialize
      @queue = Thread::Queue.new
      @mutex = Mutex.new
    end

    # Add a work item to the queue (thread-safe)
    # @param work_item [Fractor::Work] The work item to add
    # @return [void]
    def <<(work_item)
      unless work_item.is_a?(Fractor::Work)
        raise ArgumentError,
              "#{work_item.class} must be an instance of Fractor::Work"
      end

      @queue << work_item
    end

    # Retrieve multiple work items from the queue in a single operation
    # @param max_items [Integer] Maximum number of items to retrieve
    # @return [Array<Fractor::Work>] Array of work items (may be empty)
    def pop_batch(max_items = 10)
      items = []
      max_items.times do
        break if @queue.empty?

        begin
          items << @queue.pop(true)
        rescue ThreadError
          # Queue became empty between check and pop
          break
        end
      end
      items
    end

    # Check if the queue is empty
    # @return [Boolean] true if the queue is empty
    def empty?
      @queue.empty?
    end

    # Get the current size of the queue
    # @return [Integer] Number of items in the queue
    def size
      @queue.size
    end

    # Register this work queue as a work source with a supervisor
    # @param supervisor [Fractor::Supervisor] The supervisor to register with
    # @param batch_size [Integer] Number of items to retrieve per poll
    # @return [void]
    def register_with_supervisor(supervisor, batch_size: 10)
      supervisor.register_work_source do
        items = pop_batch(batch_size)
        items.empty? ? nil : items
      end
    end
  end
end
