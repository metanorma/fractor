# frozen_string_literal: true

require "logger"
require "json"
require "time"

module Fractor
  class Workflow
    # Logger wrapper for workflow execution logging.
    # Provides structured logging with correlation IDs and context.
    class WorkflowLogger
      attr_reader :logger, :correlation_id

      def initialize(logger: nil, correlation_id: nil)
        @logger = logger || default_logger
        @correlation_id = correlation_id || generate_correlation_id
      end

      # Log an info message with structured context
      def info(message, context = {})
        log(:info, message, context)
      end

      # Log a warning message with structured context
      def warn(message, context = {})
        log(:warn, message, context)
      end

      # Log an error message with structured context
      def error(message, context = {})
        log(:error, message, context)
      end

      # Log a debug message with structured context
      def debug(message, context = {})
        log(:debug, message, context)
      end

      # Create a child logger with additional context
      def child(additional_context = {})
        child_logger = self.class.new(
          logger: @logger,
          correlation_id: @correlation_id,
        )
        child_logger.instance_variable_set(
          :@base_context,
          base_context.merge(additional_context),
        )
        child_logger
      end

      private

      def log(level, message, context)
        return unless should_log?(level)

        log_data = build_log_data(level, message, context)
        formatted_message = format_message(log_data)
        @logger.send(level, formatted_message)
      end

      def should_log?(level)
        @logger.send("#{level}?")
      end

      def build_log_data(level, message, context)
        {
          timestamp: Time.now.utc.strftime("%Y-%m-%dT%H:%M:%S.%3NZ"),
          level: level.to_s.upcase,
          correlation_id: @correlation_id,
          message: message,
        }.merge(base_context).merge(context)
      end

      def format_message(log_data)
        # Simple key=value format for readability
        parts = log_data.map { |k, v| "#{k}=#{format_value(v)}" }
        parts.join(" ")
      end

      def format_value(value)
        case value
        when String
          value.include?(" ") ? "\"#{value}\"" : value
        when Hash, Array
          value.to_json
        else
          value.to_s
        end
      end

      def base_context
        @base_context ||= {}
      end

      def default_logger
        Logger.new($stdout).tap do |log|
          log.level = Logger::INFO
          log.formatter = proc do |_severity, _datetime, _progname, msg|
            "#{msg}\n"
          end
        end
      end

      def generate_correlation_id
        "wf-#{SecureRandom.hex(8)}"
      end
    end
  end
end
