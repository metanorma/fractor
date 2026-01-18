# frozen_string_literal: true

module Fractor
  # Base class for defining work items.
  # Contains the input data for a worker.
  class Work
    attr_reader :input

    def initialize(input)
      @input = input
    end

    def to_s
      "Work: #{@input}"
    end

    # Provide detailed inspection of work item for debugging
    # @return [String] Detailed inspection string
    def inspect
      details = [
        "#<#{self.class.name}",
        "0x#{(object_id << 1).to_s(16)}",
        "@input=#{@input.inspect}",
        "@type=#{input.class.name}",
      ]
      details.join(" ")
    end
  end
end
