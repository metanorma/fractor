# frozen_string_literal: true

require "timeout"

module Fractor
  # Base class for defining work processors.
  # Subclasses must implement the `process` method.
  class Worker
    class << self
      attr_reader :input_type_class, :output_type_class, :worker_timeout

      # Declare the input type for this worker.
      # Used by the workflow system to validate data flow.
      #
      # @param klass [Class] A Lutaml::Model::Serializable subclass
      def input_type(klass)
        validate_type_class!(klass, "input_type")
        @input_type_class = klass
      end

      # Declare the output type for this worker.
      # Used by the workflow system to validate data flow.
      #
      # @param klass [Class] A Lutaml::Model::Serializable subclass
      def output_type(klass)
        validate_type_class!(klass, "output_type")
        @output_type_class = klass
      end

      # Set a timeout for this worker's process method.
      # If the process method takes longer than this, a Timeout::Error will be raised.
      #
      # @param seconds [Numeric] Timeout in seconds
      def timeout(seconds)
        @worker_timeout = seconds
      end

      # Get the effective timeout for this worker.
      # Returns the worker-specific timeout, or the global default if not set.
      # Note: This method accesses Fractor.config and should be called from
      # the main ractor context, not from within worker ractors.
      #
      # @return [Numeric, nil] Timeout in seconds, or nil if not configured
      def effective_timeout
        @worker_timeout || begin
          # Access config safely - this must be called from main ractor
          Fractor.config.default_worker_timeout
        end
      end

      private

      def validate_type_class!(klass, method_name)
        # Allow any class for now, stricter validation can be added later
        # In production, you'd want to check for Lutaml::Model::Serializable
        return if klass.is_a?(Class)

        raise ArgumentError, "#{method_name} must be a Class"
      end
    end

    def initialize(name: nil, **options)
      @name = name
      @options = options
      # If timeout is not provided or is nil, fall back to class-level timeout
      # Note: This must only be called from the main ractor, not from within worker ractors.
      # In the ractor context, timeout should always be passed explicitly.
      if !@options.key?(:timeout) || @options[:timeout].nil?
        @options[:timeout] = self.class.worker_timeout
      end
    end

    def process(work)
      raise NotImplementedError,
            "Subclasses must implement the 'process' method."
    end

    # Get the timeout for this worker instance.
    # Uses the class-level timeout if not overridden.
    # Note: This method is safe to call from within ractors as it only
    # accesses instance variables that were set at initialization time.
    #
    # @return [Numeric, nil] Timeout in seconds, or nil if not configured
    def timeout
      # The timeout is always set at initialization time via options,
      # so we can safely access it from within the ractor
      @options[:timeout]
    end
  end
end
