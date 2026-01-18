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

    # Get a summary of errors
    # @return [Hash] Error summary with counts, categories, and other stats
    def errors_summary
      return {} if @errors.empty?

      # Group errors by category
      by_category = @errors.group_by do |e|
        e.error_category || :unknown
      end.transform_values(&:count)

      # Group errors by severity
      by_severity = @errors.group_by do |e|
        e.error_severity || :unknown
      end.transform_values(&:count)

      # Count error types (class names)
      error_types = @errors.map do |e|
        e.error&.class&.name || e.error&.class || "String"
      end.tally

      # Get unique error messages (first 10)
      unique_messages = @errors.map { |e| e.error.to_s }.uniq.first(10)

      {
        total_errors: @errors.size,
        by_category: by_category,
        by_severity: by_severity,
        error_types: error_types,
        sample_messages: unique_messages,
      }
    end
  end
end
