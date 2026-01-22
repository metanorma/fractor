# frozen_string_literal: true

# Require all component files
require_relative "fractor/version"
require_relative "fractor/configuration"
require_relative "fractor/logger"
require_relative "fractor/work"
require_relative "fractor/work_result"
require_relative "fractor/work_queue"
require_relative "fractor/queue_persister"
require_relative "fractor/persistent_work_queue"
require_relative "fractor/priority_work"
require_relative "fractor/priority_work_queue"
require_relative "fractor/wrapped_ractor"
require_relative "fractor/wrapped_ractor3"
require_relative "fractor/wrapped_ractor4"
require_relative "fractor/worker"
require_relative "fractor/work_distribution_manager"
require_relative "fractor/shutdown_handler"
require_relative "fractor/main_loop_handler"
require_relative "fractor/main_loop_handler3"
require_relative "fractor/main_loop_handler4"
require_relative "fractor/signal_handler"
require_relative "fractor/supervisor_logger"
require_relative "fractor/supervisor"
require_relative "fractor/result_aggregator"
require_relative "fractor/continuous_server"
require_relative "fractor/workflow"
require_relative "fractor/performance_monitor"
require_relative "fractor/performance_metrics_collector"
require_relative "fractor/performance_report_generator"
require_relative "fractor/error_reporter"
require_relative "fractor/error_statistics"
require_relative "fractor/error_report_generator"
require_relative "fractor/error_formatter"
require_relative "fractor/execution_tracer"
require_relative "fractor/result_cache"

# Optional: CLI (only load if Thor is available)
begin
  require "thor"
  require_relative "fractor/cli"
rescue LoadError
  # Thor not available, CLI commands will not be available
end

# Fractor: Function-driven Ractors framework
module Fractor
  # Exception raised when trying to push to a closed queue
  class ClosedQueueError < StandardError; end

  # Configure Fractor with a block.
  #
  # @yield [Configuration] The configuration object
  #
  # @example
  #   Fractor.configure do |config|
  #     config.debug = true
  #     config.logger = Logger.new(STDOUT)
  #     config.default_worker_timeout = 60
  #   end
  def self.configure(&)
    Configuration.configure(&)
  end

  # Load configuration from a YAML file.
  #
  # @param file_path [String] Path to the YAML configuration file
  def self.configure_from_file(file_path)
    Configuration.configure_from_file(file_path)
  end

  # Load configuration from environment variables.
  # Environment variables should be prefixed with FRACTOR_.
  #
  # @example
  #   # Set environment variables
  #   # export FRACTOR_DEBUG=true
  #   # export FRACTOR_DEFAULT_WORKER_TIMEOUT=60
  #
  #   Fractor.configure_from_env
  def self.configure_from_env
    Configuration.configure_from_env
  end

  # Access the global configuration instance.
  #
  # @return [Configuration] The configuration instance
  def self.config
    Configuration.config
  end

  # Reset all global state to ensure isolation between different uses of Fractor.
  # This is important for testing and when multiple gems use Fractor together.
  #
  # @example Reset state between tests
  #   Fractor.reset!  # Clears logger, tracer, and other global state
  def self.reset!
    Configuration.reset!
    ExecutionTracer.reset!
    reset_logger!
  end

  # Reset logger state (internal method, use reset! instead)
  def self.reset_logger!
    @logger = nil if defined?(@logger)
  end
end
