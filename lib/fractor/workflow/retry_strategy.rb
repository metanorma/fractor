# frozen_string_literal: true

module Fractor
  class Workflow
    # Base class for retry strategies
    class RetryStrategy
      attr_reader :max_attempts, :max_delay

      def initialize(max_attempts: 3, max_delay: nil)
        @max_attempts = max_attempts
        @max_delay = max_delay
      end

      # Calculate delay for the given attempt number
      # @param attempt [Integer] The attempt number (1-based)
      # @return [Numeric] Delay in seconds
      def delay_for(attempt)
        raise NotImplementedError, "Subclasses must implement delay_for"
      end

      protected

      def cap_delay(delay)
        return delay unless max_delay

        [delay, max_delay].min
      end
    end

    # Exponential backoff retry strategy
    class ExponentialBackoff < RetryStrategy
      attr_reader :initial_delay, :multiplier

      def initialize(initial_delay: 1, multiplier: 2, **options)
        super(**options)
        @initial_delay = initial_delay
        @multiplier = multiplier
      end

      def delay_for(attempt)
        return 0 if attempt <= 1

        delay = initial_delay * (multiplier**(attempt - 2))
        cap_delay(delay)
      end
    end

    # Linear backoff retry strategy
    class LinearBackoff < RetryStrategy
      attr_reader :initial_delay, :increment

      def initialize(initial_delay: 1, increment: 1, **options)
        super(**options)
        @initial_delay = initial_delay
        @increment = increment
      end

      def delay_for(attempt)
        return 0 if attempt <= 1

        delay = initial_delay + (increment * (attempt - 2))
        cap_delay(delay)
      end
    end

    # Constant delay retry strategy
    class ConstantDelay < RetryStrategy
      attr_reader :delay

      def initialize(delay: 1, **options)
        super(**options)
        @delay = delay
      end

      def delay_for(attempt)
        return 0 if attempt <= 1

        cap_delay(delay)
      end
    end

    # No retry strategy
    class NoRetry < RetryStrategy
      def initialize
        super(max_attempts: 1)
      end

      def delay_for(_attempt)
        0
      end
    end
  end
end
