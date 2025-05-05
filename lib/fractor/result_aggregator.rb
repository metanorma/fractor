# frozen_string_literal: true

module Fractor
  # Aggregates results and errors from worker Ractors.
  class ResultAggregator
    attr_reader :results, :errors

    def initialize
      @results = []
      @errors = []
    end

    def add_result(result)
      if result.success?
        puts "Work completed successfully: #{result}"
        @results << result
      else
        puts "Error processing work: #{result}"
        @errors << result
      end
    end

    def to_s
      "Results: #{@results.size}, Errors: #{@errors.size}"
    end

    def inspect
      {
        results: @results.map(&:inspect),
        errors: @errors.map(&:inspect)
      }
    end
  end
end
