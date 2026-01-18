# frozen_string_literal: true

module Fractor
  # PriorityWork extends Work with priority levels for priority-based scheduling
  #
  # Priority levels:
  # - :critical - Highest priority, processed first
  # - :high - High priority
  # - :normal - Default priority (backward compatible)
  # - :low - Low priority
  # - :background - Lowest priority
  #
  # @example Creating priority work
  #   work = Fractor::PriorityWork.new(data: "urgent task", priority: :high)
  #
  # @example Using default priority
  #   work = Fractor::PriorityWork.new(data: "normal task")
  #   work.priority # => :normal
  class PriorityWork < Work
    PRIORITY_LEVELS = {
      critical: 0,
      high: 1,
      normal: 2,
      low: 3,
      background: 4,
    }.freeze

    attr_reader :priority, :created_at

    # Initialize a new PriorityWork
    #
    # @param input [Object] The input data for the work
    # @param priority [Symbol] Priority level (:critical, :high, :normal, :low, :background)
    # @raise [ArgumentError] if priority is not a valid level
    def initialize(input, priority: :normal)
      super(input)
      validate_priority!(priority)
      @priority = priority
      @created_at = Time.now
    end

    # Get numeric priority value (lower is higher priority)
    #
    # @return [Integer] Numeric priority (0-4)
    def priority_value
      PRIORITY_LEVELS[@priority]
    end

    # Calculate age in seconds (used for priority aging)
    #
    # @return [Float] Age in seconds since creation
    def age
      Time.now - @created_at
    end

    # Compare priorities for sorting
    # Lower priority value = higher priority
    # For same priority, older work comes first (FIFO within priority)
    #
    # @param other [PriorityWork] Other work to compare with
    # @return [Integer] -1, 0, or 1 for comparison
    def <=>(other)
      return nil unless other.is_a?(PriorityWork)

      # First compare by priority value
      result = priority_value <=> other.priority_value
      return result unless result.zero?

      # If same priority, use FIFO (older first)
      created_at <=> other.created_at
    end

    # Check if this work has higher priority than another
    #
    # @param other [PriorityWork] Other work to compare with
    # @return [Boolean] true if this work has higher priority
    def higher_priority_than?(other)
      return false unless other.is_a?(PriorityWork)

      priority_value < other.priority_value
    end

    private

    def validate_priority!(priority)
      return if PRIORITY_LEVELS.key?(priority)

      raise ArgumentError,
            "Invalid priority: #{priority}. " \
            "Must be one of: #{PRIORITY_LEVELS.keys.join(', ')}"
    end
  end
end
