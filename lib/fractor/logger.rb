# frozen_string_literal: true

require "logger"

module Fractor
  class << self
    attr_writer :logger

    # Get the Fractor logger instance
    # @return [Logger] Logger instance
    def logger
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
    def reset!
      @logger = nil
    end
  end

  # Ractor-safe logging module.
  #
  # This module provides logging functionality that works correctly
  # within Ractors by using $stderr for unbuffered output.
  #
  # @example Inside a worker or ractor
  #   Fractor::RactorLogger.debug("Processing work", ractor_name: "worker-1")
  #   Fractor::RactorLogger.info("Worker started", ractor_name: "worker-1")
  #   Fractor::RactorLogger.warn("Long processing time", ractor_name: "worker-1")
  #   Fractor::RactorLogger.error("Worker failed", ractor_name: "worker-1", exception: e)
  #
  module RactorLogger
    # Log levels in order of severity
    LEVELS = {
      debug: 0,
      info: 1,
      warn: 2,
      error: 3,
    }.freeze

    class << self
      # Get or set the current log level
      # @return [Symbol] Current log level (:debug, :info, :warn, :error)
      attr_accessor :level

      # Enable or disable logging
      # @return [Boolean] Whether logging is enabled
      attr_accessor :enabled

      # Enable debug mode (sets level to :debug)
      def debug!
        self.level = :debug
        self.enabled = true
      end

      # Disable debug mode (sets level to :warn)
      def nodebug!
        self.level = :warn
        self.enabled = false
      end

      # Check if a given log level would be logged
      # @param lvl [Symbol] Log level to check
      # @return [Boolean] True if messages at this level would be logged
      def log?(lvl)
        enabled && LEVELS[lvl.to_sym] >= LEVELS[level]
      end

      # Log a debug message
      # @param message [String] Message to log
      # @param ractor_name [String, nil] Name of the ractor (optional)
      def debug(message, ractor_name: nil)
        return unless log?(:debug)

        log(:debug, message, ractor_name: ractor_name)
      end

      # Log an info message
      # @param message [String] Message to log
      # @param ractor_name [String, nil] Name of the ractor (optional)
      def info(message, ractor_name: nil)
        return unless log?(:info)

        log(:info, message, ractor_name: ractor_name)
      end

      # Log a warning message
      # @param message [String] Message to log
      # @param ractor_name [String, nil] Name of the ractor (optional)
      def warn(message, ractor_name: nil)
        return unless log?(:warn)

        log(:warn, message, ractor_name: ractor_name)
      end

      # Log an error message
      # @param message [String] Message to log
      # @param ractor_name [String, nil] Name of the ractor (optional)
      # @param exception [Exception, nil] Exception object (optional)
      def error(message, ractor_name: nil, exception: nil)
        return unless log?(:error)

        log(:error, message, ractor_name: ractor_name, exception: exception)
      end

      private

      # Internal logging method
      # @param level [Symbol] Log level
      # @param message [String] Message to log
      # @param ractor_name [String, nil] Name of the ractor
      # @param exception [Exception, nil] Exception object
      def log(level, message, ractor_name: nil, exception: nil)
        timestamp = Time.now.strftime("%Y-%m-%d %H:%M:%S.%3N")
        level_tag = level.to_s.upcase.ljust(5)

        # Format: [TIMESTAMP] [LEVEL] [RACTOR] message
        ractor_tag = ractor_name ? "[#{ractor_name}] " : ""
        output = "[#{timestamp}] [#{level_tag}] #{ractor_tag}#{message}"

        # Always use $stderr for immediate, unbuffered output
        warn(output)
        $stderr.flush

        # If there's an exception, log the stack trace
        if exception
          warn("[#{timestamp}] [#{level_tag}] #{ractor_tag}#{exception.class}: #{exception.message}")
          exception.backtrace&.each do |line|
            warn("[#{timestamp}] [#{level_tag}] #{ractor_tag}    #{line}")
          end
          $stderr.flush
        end
      end
    end

    # Initialize with defaults - check FRACTOR_DEBUG environment variable
    @enabled = ["1", "true"].include?(ENV["FRACTOR_DEBUG"])
    @level = @enabled ? :debug : :info
  end
end
