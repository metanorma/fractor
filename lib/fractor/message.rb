# frozen_string_literal: true

module Fractor
  class Message
    attr_reader :type, :params

    @@message_specs = {}

    class << self
      # Define a message type and its parameter specification
      def message(type, &spec_block)
        @@message_specs[type] = spec_block

        # Create a factory method for this message type
        define_singleton_method(type) do |**params|
          new(type: type, params: params)
        end
      end

      # Get the specification for a message type
      def spec_for(type)
        @@message_specs[type]
      end

      # List all registered message types
      def registered_types
        @@message_specs.keys
      end
    end

    # Define standard messages
    message :process do
      param :work, required: true
    end

    message :terminate do
      # No parameters needed
    end

    message :ping do
      # No parameters needed
    end

    message :pong do
      param :worker_id, required: true
    end

    message :result do
      param :result, required: true
    end

    message :error do
      param :work, required: false
      param :error_details, required: true
    end

    message :fatal_error do
      param :error_details, required: true
    end

    def initialize(type:, params: {})
      @type = type
      @params = params
      validate!
    end

    def validate!
      spec = self.class.spec_for(@type)

      if spec
        # Execute the specification block in an evaluation context
        # that tracks required parameters and their types
        context = SpecEvaluator.new
        context.instance_exec(&spec)

        # Check required parameters
        context.required_params.each do |param_name|
          unless @params.key?(param_name)
            raise ArgumentError, "Missing required parameter: #{param_name} for message type: #{@type}"
          end
        end
      end
    end

    def shareable?
      # Check if all params are shareable
      @params.values.all? do |value|
        value.respond_to?(:shareable?) ? value.shareable? : true
      end
    end

    def to_a
      [@type, @params]
    end

    # Helper class for evaluating message specifications
    class SpecEvaluator
      attr_reader :required_params

      def initialize
        @required_params = []
      end

      def param(name, required: false, type: nil)
        @required_params << name if required
      end
    end
  end
end
