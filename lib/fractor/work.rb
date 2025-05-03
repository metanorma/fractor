# frozen_string_literal: true

module Fractor
  class Work
    attr_reader :data, :attempt_count
    attr_accessor :max_retries

    class << self
      def work_type(type = nil)
        @work_type = type if type
        @work_type
      end
    end

    def initialize(data: {})
      @data = data
      @attempt_count = 0
      @max_retries = 3 # Default value, can be overridden
      validate
    end

    def work_type
      self.class.work_type
    end

    def validate
      # To be overridden by subclasses
    end

    def shareable?
      # Check if this work object can be shared between ractors
      true
    end

    def failed
      @attempt_count += 1
    end

    def should_retry?
      @attempt_count <= @max_retries
    end
  end
end
