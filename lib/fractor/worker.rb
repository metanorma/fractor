# frozen_string_literal: true

module Fractor
  # Base class for defining work processors.
  # Subclasses must implement the `process` method.
  class Worker
    class << self
      attr_reader :input_type_class, :output_type_class

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
    end

    def process(work)
      raise NotImplementedError,
            "Subclasses must implement the 'process' method."
    end
  end
end
