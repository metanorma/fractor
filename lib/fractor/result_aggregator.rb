# frozen_string_literal: true

module Fractor
  # Aggregates results and errors from worker Ractors.
  class ResultAggregator
    attr_reader :results, :errors

    def initialize
      @results = []
      @errors = []
      @result_callbacks = []
    end

    def add_result(result)
      if result.success?
        puts "Work completed successfully: Result: #{result.result}" if ENV["FRACTOR_DEBUG"]
        @results << result
      else
        puts "Error processing work: #{result}" if ENV["FRACTOR_DEBUG"]
        @errors << result
      end

      # Call any registered callbacks with the new result
      @result_callbacks.each { |callback| callback.call(result) }
    end

    # Register a callback to be called when a new result is added
    def on_new_result(&callback)
      @result_callbacks << callback
    end

    def to_s
      "Results: #{@results.size}, Errors: #{@errors.size}"
    end

    def inspect
      {
        results: @results.map(&:inspect),
        errors: @errors.map(&:inspect),
      }
    end
  end
end
