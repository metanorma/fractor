# frozen_string_literal: true

module Fractor
  # Configuration schema validation module.
  #
  # Provides declarative configuration schemas with validation.
  # Useful for validating configuration options at initialization time.
  #
  # @example Define a schema
  #   class MyConfig
  #     extend Fractor::ConfigSchema
  #
  #     schema :worker_pools do
  #       type Array
  #       default []
  #       description "Array of worker pool configurations"
  #     end
  #
  #     schema :continuous_mode do
  #       type :boolean
  #       default false
  #       description "Whether to run in continuous mode"
  #     end
  #   end
  #
  # @example Validate configuration
  #   MyConfig.validate!(worker_pools: [...], continuous_mode: true)
  module ConfigSchema
    # Schema entry definition
    class SchemaEntry
      attr_reader :name, :type, :default, :optional, :description

      def initialize(name, **options)
        @name = name
        @type = options[:type]
        @default = options[:default]
        @optional = options.fetch(:optional, true)
        @description = options[:description]
      end

      # Validate a value against this schema entry
      # @return [Array<String>] Array of error messages (empty if valid)
      def validate(value)
        errors = []

        # Check nil for optional fields
        if value.nil?
          errors << "#{name} is required" unless @optional
          return errors
        end

        # Type validation
        if @type && !type_matches?(value)
          errors << "#{name} must be of type #{type_description}, got #{value.class}"
        end

        errors
      end

      private

      def type_matches?(value)
        case @type
        when :boolean
          value.is_a?(TrueClass) || value.is_a?(FalseClass)
        when Class
          value.is_a?(@type)
        when Array
          @type.any? { |t| value.is_a?(t) }
        else
          true # No type constraint
        end
      end

      def type_description
        case @type
        when :boolean
          "boolean"
        when Class
          @type.name
        when Array
          @type.map { |t| t.is_a?(Class) ? t.name : t.to_s }.join(" or ")
        else
          "any"
        end
      end
    end

    # Module-level methods for defining schemas
    def self.extended(base)
      base.instance_variable_set(:@schema_entries, {})
      base.singleton_class.prepend(SchemaClassMethods)
    end

    module SchemaClassMethods
      # Define a configuration schema entry
      # @param name [Symbol] Configuration key name
      # @param options [Hash] Schema options (type, default, optional, description)
      def schema(name, **options)
        @schema_entries ||= {}
        @schema_entries[name] = SchemaEntry.new(name, **options)
      end

      # Get all schema entries
      # @return [Hash] Schema entries by name
      def schema_entries
        @schema_entries || {}
      end

      # Validate configuration against schema
      # @param config [Hash] Configuration to validate
      # @raise [ArgumentError] If configuration is invalid
      # @return [Hash] Validated and normalized configuration
      def validate!(config = {})
        all_errors = []

        schema_entries.each do |name, entry|
          value = config.fetch(name, entry.default)
          errors = entry.validate(value)
          all_errors.concat(errors.map { |e| "- #{e}" })
        end

        # Check for unknown keys
        unknown_keys = config.keys - schema_entries.keys.symbolize_keys
        unknown_keys.each do |key|
          all_errors << "- Unknown configuration option: #{key}"
        end

        unless all_errors.empty?
          raise ArgumentError,
                "Invalid configuration:\n#{all_errors.join("\n")}\n\n" \
                "Valid options:\n#{schema_help}"
        end

        config
      end

      # Generate schema help text
      # @return [String] Help text describing all schema entries
      def schema_help
        lines = []
        schema_entries.each_value do |entry|
          type_desc = case entry.type
                      when :boolean then "boolean"
                      when Class then entry.type.name
                      when Array then entry.type.map(&:name).join(" | ")
                      else "any"
                      end
          default_desc = entry.optional ? " (default: #{entry.default.inspect})" : " (required)"
          desc = entry.description ? " - #{entry.description}" : ""
          lines << "  #{entry.name}: #{type_desc}#{default_desc}#{desc}"
        end
        lines.join("\n")
      end

      # Get schema as a hash (for documentation purposes)
      # @return [Hash] Schema definition
      def schema_definition
        schema_entries.transform_values do |entry|
          {
            type: entry.type,
            default: entry.default,
            optional: entry.optional,
            description: entry.description,
          }
        end
      end
    end
  end
end
