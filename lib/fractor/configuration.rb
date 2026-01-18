# frozen_string_literal: true

require "yaml"
require "logger"

module Fractor
  # Central configuration management for Fractor.
  # Provides a unified way to configure all Fractor components.
  #
  # @example Basic configuration
  #   Fractor.configure do |config|
  #     config.logger = Logger.new(STDOUT)
  #     config.debug = true
  #     config.default_worker_timeout = 30
  #   end
  #
  # @example Loading from YAML file
  #   Fractor.configure_from_file("config/fractor.yml")
  #
  # @example Environment variable support
  #   # Set FRACTOR_DEBUG=true to enable debug mode
  #   Fractor.config.debug # => true
  class Configuration
    # Default configuration values
    DEFAULTS = {
      debug: false,
      log_level: Logger::INFO,
      default_worker_timeout: 120,
      default_max_retries: 3,
      default_retry_delay: 1,
      enable_performance_monitoring: false,
      enable_error_reporting: false,
      ractor_pool_size: nil, # nil = auto-detect (CPU count)
      workflow_validation_strict: true,
      thread_safe: true,
    }.freeze

    # Get the logger instance (creates default if not set).
    #
    # @return [Logger] The logger instance
    def logger
      @logger ||= create_default_logger
    end

    # Set the logger instance.
    #
    # @param logger_instance [Logger] The logger to use
    def logger=(logger_instance)
      @logger = logger_instance
    end

    # Check if debug logging is enabled.
    #
    # @return [Boolean] true if debug is enabled
    def debug_enabled?
      debug && logger&.debug?
    end

    # Other configuration attributes
    attr_accessor :debug, :log_level, :default_worker_timeout,
                  :default_max_retries, :default_retry_delay,
                  :enable_performance_monitoring, :enable_error_reporting,
                  :ractor_pool_size, :workflow_validation_strict, :thread_safe

    # Class-level configuration instance
    @instance = nil
    @mutex = Mutex.new

    class << self
      # Get the global configuration instance.
      #
      # @return [Configuration] The configuration instance
      def instance
        return @instance if @instance

        @mutex.synchronize do
          @instance ||= new
        end
      end

      # Configure Fractor with a block.
      #
      # @yield [Configuration] The configuration object
      #
      # @example
      #   Fractor.configure do |config|
      #     config.debug = true
      #     config.logger = custom_logger
      #   end
      def configure
        yield instance if block_given?
        instance
      end

      # Load configuration from a YAML file.
      #
      # @param file_path [String] Path to the YAML configuration file
      # @raise [ArgumentError] if file doesn't exist
      # @raise [ConfigurationError] if YAML is invalid
      #
      # @example
      #   # config/fractor.yml
      #   debug: true
      #   log_level: DEBUG
      #   default_worker_timeout: 60
      #
      #   Fractor.configure_from_file("config/fractor.yml")
      def configure_from_file(file_path)
        unless File.exist?(file_path)
          raise ArgumentError, "Configuration file not found: #{file_path}"
        end

        config_data = YAML.load_file(file_path)
        apply_config(config_data)
      end

      # Load configuration from a hash.
      #
      # @param config_hash [Hash] Configuration options
      def apply_config(config_hash)
        return if config_hash.nil? || config_hash.empty?

        config_hash.each do |key, value|
          setter = "#{key}="
          if instance.respond_to?(setter)
            instance.public_send(setter, value)
          else
            warn "Unknown configuration option: #{key}"
          end
        end
      end

      # Load configuration from environment variables.
      # Environment variables should be prefixed with FRACTOR_.
      #
      # @example
      #   # Set environment variable
      #   # export FRACTOR_DEBUG=true
      #   # export FRACTOR_DEFAULT_WORKER_TIMEOUT=60
      #
      #   Fractor.configure_from_env
      def configure_from_env
        env_config = {}

        ENV.each do |key, value|
          next unless key.start_with?("FRACTOR_")

          config_key = key.sub(/^FRACTOR_/, "").downcase
          config_key = underscore_to_camelcase(config_key)

          # Convert string values to appropriate types
          typed_value = parse_env_value(value)
          env_config[config_key] = typed_value
        end

        apply_config(env_config)
      end

      # Reset configuration to defaults.
      # Useful for testing.
      def reset!
        @mutex.synchronize do
          @instance = new
        end
      end

      # Access configuration properties directly on Fractor.
      #
      # @example
      #   Fractor.config.debug
      #   Fractor.config.logger
      def config
        instance
      end

      private

      # Convert FRACTOR_DEFAULT_WORKER_TIMEOUT to default_worker_timeout
      def underscore_to_camelcase(str)
        str.gsub(/_(.)/) { Regexp.last_match(1).upcase }
      end

      # Parse environment variable value to appropriate type
      def parse_env_value(value)
        case value
        when "true"
          true
        when "false"
          false
        when /^\d+$/
          value.to_i
        when /^\d+\.\d+$/
          value.to_f
        else
          value
        end
      end
    end

    # Initialize a new configuration with default values.
    def initialize
      apply_defaults
    end

    # Get a configuration value by key.
    #
    # @param key [Symbol] The configuration key
    # @return [Object] The configuration value
    def [](key)
      public_send(key) if respond_to?(key)
    end

    # Set a configuration value by key.
    #
    # @param key [Symbol] The configuration key
    # @param value [Object] The value to set
    def []=(key, value)
      setter = "#{key}="
      public_send(setter, value) if respond_to?(setter)
    end

    # Export configuration as hash.
    #
    # @return [Hash] Configuration as hash
    def to_h
      {
        debug: @debug,
        log_level: @log_level,
        default_worker_timeout: @default_worker_timeout,
        default_max_retries: @default_max_retries,
        default_retry_delay: @default_retry_delay,
        enable_performance_monitoring: @enable_performance_monitoring,
        enable_error_reporting: @enable_error_reporting,
        ractor_pool_size: @ractor_pool_size,
        workflow_validation_strict: @workflow_validation_strict,
        thread_safe: @thread_safe,
      }
    end

    # Validate configuration.
    #
    # @raise [ConfigurationError] if configuration is invalid
    # @return [Boolean] true if valid
    def validate!
      validate_timeouts!
      validate_retries!
      validate_pool_size!
      true
    end

    private

    def apply_defaults
      @debug = DEFAULTS[:debug]
      @log_level = DEFAULTS[:log_level]
      @logger = nil # Will use default logger if not set
      @default_worker_timeout = DEFAULTS[:default_worker_timeout]
      @default_max_retries = DEFAULTS[:default_max_retries]
      @default_retry_delay = DEFAULTS[:default_retry_delay]
      @enable_performance_monitoring = DEFAULTS[:enable_performance_monitoring]
      @enable_error_reporting = DEFAULTS[:enable_error_reporting]
      @ractor_pool_size = DEFAULTS[:ractor_pool_size]
      @workflow_validation_strict = DEFAULTS[:workflow_validation_strict]
      @thread_safe = DEFAULTS[:thread_safe]
    end

    def validate_timeouts!
      if @default_worker_timeout && @default_worker_timeout <= 0
        raise ConfigurationError,
              "default_worker_timeout must be positive, got: #{@default_worker_timeout}"
      end
    end

    def validate_retries!
      if @default_max_retries&.negative?
        raise ConfigurationError,
              "default_max_retries must be non-negative, got: #{@default_max_retries}"
      end

      if @default_retry_delay&.negative?
        raise ConfigurationError,
              "default_retry_delay must be non-negative, got: #{@default_retry_delay}"
      end
    end

    def validate_pool_size!
      return unless @ractor_pool_size

      if @ractor_pool_size <= 0
        raise ConfigurationError,
              "ractor_pool_size must be positive, got: #{@ractor_pool_size}"
      end
    end

    def create_default_logger
      logger = Logger.new($stdout)
      logger.level = @log_level || Logger::INFO
      logger.formatter = proc do |severity, datetime, _progname, msg|
        "[#{datetime.strftime('%Y-%m-%d %H:%M:%S')}] #{severity}: #{msg}\n"
      end
      logger
    end
  end

  # Error raised when configuration is invalid.
  class ConfigurationError < StandardError; end
end
