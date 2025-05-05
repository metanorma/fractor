# frozen_string_literal: true

module Fractor
  # Represents the result of processing a Work item.
  # Can hold either a successful result or an error.
  class WorkResult
    attr_reader :result, :error, :work

    def initialize(result: nil, error: nil, work: nil)
      @result = result
      @error = error
      @work = work
    end

    def success?
      !@error
    end

    def to_s
      if success?
        "Result: #{@result}"
      else
        "Error: #{@error}, Work: #{@work}"
      end
    end

    def inspect
      {
        result: @result,
        error: @error,
        work: @work&.to_s # Use safe navigation for work
      }
    end
  end
end
