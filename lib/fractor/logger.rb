# frozen_string_literal: true

require "logger"

module Fractor
  class << self
    # Disabled logger for use in Ractors (Ractor isolation prohibits shared instance variables)
    RACTOR_LOGGER = Logger.new(nil).tap { |l| l.level = Logger::UNKNOWN }.freeze

    attr_writer :logger

    # Get the Fractor logger instance
    # @return [Logger] Logger instance (disabled in Ractors, defaults to STDOUT/INFO in main)
    def logger
      # Ractors cannot access module instance variables, so always return disabled logger
      return RACTOR_LOGGER if defined?(Ractor) && Ractor.current != Ractor.main

      # Main ractor - use instance variable with sensible defaults
      @logger ||= create_default_logger
    end

    # Enable debug logging to STDOUT
    # @return [Logger] The configured logger
    def enable_logging(level = Logger::DEBUG)
      main_logger = create_logger_for_output($stdout, level)
      @logger = main_logger
      main_logger
    end

    # Disable logging entirely
    def disable_logging
      @logger = create_disabled_logger
    end

    # Check if debug logging is enabled
    def debug_enabled?
      # Always false in Ractors
      return false if defined?(Ractor) && Ractor.current != Ractor.main

      @logger&.debug?
    end

    private

    # Create default logger with sensible defaults
    # Respects FRACTOR_LOG_LEVEL and FRACTOR_LOG_OUTPUT environment variables
    # @return [Logger] Configured logger instance
    def create_default_logger
      # Get log level from environment variable or use INFO as default
      level = parse_log_level(ENV["FRACTOR_LOG_LEVEL"]) || Logger::INFO

      # Get output destination from environment variable or use STDOUT as default
      output = parse_log_output(ENV["FRACTOR_LOG_OUTPUT"]) || $stdout

      create_logger_for_output(output, level)
    end

    # Create a logger for the specified output with the given level
    # @param output [IO, String, nil] Output destination
    # @param level [Integer] Log level
    # @return [Logger] Configured logger instance
    def create_logger_for_output(output, level)
      logger = Logger.new(output)
      logger.level = level
      logger.formatter = proc do |severity, datetime, _progname, msg|
        "[#{datetime.strftime('%Y-%m-%d %H:%M:%S')}] #{severity}: #{msg}\n"
      end
      logger
    end

    # Parse log level from environment variable string
    # @param level_str [String, nil] Log level string (DEBUG, INFO, WARN, ERROR)
    # @return [Integer, nil] Logger constant or nil if invalid
    def parse_log_level(level_str)
      return nil unless level_str

      case level_str.to_s.upcase
      when "DEBUG" then Logger::DEBUG
      when "INFO" then Logger::INFO
      when "WARN" then Logger::WARN
      when "ERROR" then Logger::ERROR
      when "FATAL" then Logger::FATAL
      when "UNKNOWN" then Logger::UNKNOWN
      end
    end

    # Parse log output destination from environment variable string
    # @param output_str [String, nil] Output destination (stdout, stderr, or file path)
    # @return [IO, nil] Output destination
    def parse_log_output(output_str)
      return nil unless output_str

      case output_str.to_s.downcase
      when "stdout" then $stdout
      when "stderr" then $stderr
      else
        # Treat as file path
        begin
          File.open(output_str.to_s, "a")
        rescue ArgumentError, IOError => e
          warn "Failed to open log file #{output_str}: #{e.message}, using STDOUT"
          $stdout
        end
      end
    end

    # Create a disabled logger that outputs nothing
    # @return [Logger] Disabled logger instance
    def create_disabled_logger
      logger = Logger.new(nil)
      logger.level = Logger::UNKNOWN
      logger
    end

    # Reset all global state (useful for testing and isolation)
    # This ensures that multiple uses of Fractor don't pollute each other
    def reset!
      @logger = nil
    end
  end
end
