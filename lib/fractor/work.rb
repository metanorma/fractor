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
  end
end
