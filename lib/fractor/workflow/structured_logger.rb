# frozen_string_literal: true

require "logger"
require "json"

module Fractor
  class Workflow
    # Structured logger that outputs JSON-formatted logs.
    # Useful for log aggregation systems like ELK, Splunk, CloudWatch, etc.
    class StructuredLogger < WorkflowLogger
      def initialize(logger: nil, correlation_id: nil, format: :json)
        super(logger: logger, correlation_id: correlation_id)
        @format = format
      end

      private

      def format_message(log_data)
        case @format
        when :json
          log_data.to_json
        when :pretty_json
          JSON.pretty_generate(log_data)
        else
          super
        end
      end
    end
  end
end
