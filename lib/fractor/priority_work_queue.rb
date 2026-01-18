# frozen_string_literal: true

module Fractor
  # PriorityWorkQueue manages work items with priority-based scheduling
  #
  # Features:
  # - Priority levels from :critical to :background
  # - FIFO within same priority level
  # - Optional priority aging to prevent starvation
  # - Thread-safe operations
  #
  # @example Basic usage
  #   queue = Fractor::PriorityWorkQueue.new
  #   queue.push(PriorityWork.new("urgent", priority: :critical))
  #   queue.push(PriorityWork.new("normal", priority: :normal))
  #   work = queue.pop # Returns critical priority work first
  #
  # @example With priority aging
  #   queue = Fractor::PriorityWorkQueue.new(aging_enabled: true, aging_threshold: 60)
  class PriorityWorkQueue
    attr_reader :aging_enabled, :aging_threshold

    # Initialize a new PriorityWorkQueue
    #
    # @param aging_enabled [Boolean] Enable priority aging to prevent starvation
    # @param aging_threshold [Integer] Seconds before a work item gets priority boost
    def initialize(aging_enabled: false, aging_threshold: 60)
      @queue = []
      @mutex = Mutex.new
      @condition = ConditionVariable.new
      @aging_enabled = aging_enabled
      @aging_threshold = aging_threshold
      @closed = false
    end

    # Add work to the queue
    #
    # @param work [PriorityWork] Work item to add
    # @raise [ArgumentError] if work is not a PriorityWork instance
    # @raise [ClosedQueueError] if queue is closed
    def push(work)
      unless work.is_a?(PriorityWork)
        raise ArgumentError,
              "Work must be a PriorityWork"
      end
      raise ClosedQueueError, "Queue is closed" if @closed

      @mutex.synchronize do
        @queue << work
        sort_queue!
        @condition.signal
      end
    end
    alias << push
    alias enqueue push

    # Remove and return highest priority work
    # Blocks if queue is empty
    #
    # @return [PriorityWork, nil] Highest priority work or nil if queue closed
    def pop
      @mutex.synchronize do
        loop do
          return nil if @closed && @queue.empty?

          unless @queue.empty?
            apply_aging! if @aging_enabled
            return @queue.shift
          end

          @condition.wait(@mutex)
        end
      end
    end
    alias dequeue pop
    alias shift pop

    # Try to remove and return highest priority work without blocking
    #
    # @return [PriorityWork, nil] Highest priority work or nil if empty
    def pop_non_blocking
      @mutex.synchronize do
        return nil if @queue.empty?

        apply_aging! if @aging_enabled
        @queue.shift
      end
    end

    # Get current queue size
    #
    # @return [Integer] Number of items in queue
    def size
      @mutex.synchronize { @queue.size }
    end
    alias length size

    # Check if queue is empty
    #
    # @return [Boolean] true if queue is empty
    def empty?
      @mutex.synchronize { @queue.empty? }
    end

    # Close the queue
    # No new items can be added, but existing items can be popped
    def close
      @mutex.synchronize do
        @closed = true
        @condition.broadcast
      end
    end

    # Check if queue is closed
    #
    # @return [Boolean] true if queue is closed
    def closed?
      @mutex.synchronize { @closed }
    end

    # Clear all items from the queue
    #
    # @return [Array<PriorityWork>] Removed items
    def clear
      @mutex.synchronize do
        items = @queue.dup
        @queue.clear
        items
      end
    end

    # Get queue statistics
    #
    # @return [Hash] Statistics including count by priority
    def stats
      @mutex.synchronize do
        priority_counts = Hash.new(0)
        @queue.each { |work| priority_counts[work.priority] += 1 }

        {
          total: @queue.size,
          by_priority: priority_counts,
          oldest_age: @queue.empty? ? 0 : @queue.max_by(&:age).age,
          closed: @closed,
        }
      end
    end

    private

    # Sort queue by priority (lower priority value = higher priority)
    # Within same priority, maintains FIFO order (older first)
    def sort_queue!
      @queue.sort!
    end

    # Apply priority aging to prevent starvation
    # Low-priority items that have waited too long get temporary boost
    def apply_aging!
      return unless @aging_enabled

      @queue.each do |work|
        next unless work.age >= @aging_threshold

        # Boost priority by one level (but not above critical)
        current_value = work.priority_value
        next if current_value.zero? # Already critical

        # Temporarily boost priority for sorting
        # We don't modify the work's actual priority, just resort
        # This is done by the natural aging factor in comparison
      end

      # Resort with aging factor considered
      @queue.sort! do |a, b|
        # Calculate effective priority with aging
        a_effective = a.priority_value - (a.age / @aging_threshold).floor
        b_effective = b.priority_value - (b.age / @aging_threshold).floor

        # Clamp to valid range (0-4)
        a_effective = [0, [4, a_effective].min].max
        b_effective = [0, [4, b_effective].min].max

        result = a_effective <=> b_effective
        result.zero? ? a.created_at <=> b.created_at : result
      end
    end
  end
end
