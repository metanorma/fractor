# frozen_string_literal: true

module Fractor
  class Workflow
    # Validates type compatibility between jobs in workflows.
    # Ensures input/output types are properly declared and compatible.
    #
    # This validator helps catch type mismatches before workflow execution.
    class TypeCompatibilityValidator
      # Error raised when type validation fails.
      class TypeError < StandardError; end

      def initialize(jobs)
        @jobs = jobs
      end

      # Validate all job type declarations.
      # Raises TypeError if any validation fails.
      #
      # @raise [TypeError] if validation fails
      # @return [true] if validation passes
      def validate!
        @jobs.each do |job|
          check_job_compatibility(job)
        end
        true
      end

      # Check that a job's type declarations are valid.
      #
      # @param job [Job] The job to check
      # @raise [TypeError] if job has invalid type declarations
      # @return [true] if job is valid
      def check_job_compatibility(job)
        # Check if worker has input type declared
        if job.input_type
          check_type_declaration(job, :input, job.input_type)
        end

        # Check if worker has output type declared
        if job.output_type
          check_type_declaration(job, :output, job.output_type)
        end

        true
      end

      # Check that a type declaration is valid.
      #
      # @param job [Job] The job with the type declaration
      # @param direction [Symbol] :input or :output
      # @param type [Class] The type class to validate
      # @raise [TypeError] if type declaration is invalid
      # @return [true] if type is valid
      def check_type_declaration(job, direction, type)
        # Check if type is a class
        unless type.is_a?(Class)
          raise TypeError, type_declaration_error(job, direction,
                                                  "#{type.inspect} is not a class",
                                                  "Use a class like String or Integer")
        end

        # Check if type is not Object (too generic)
        if type == Object
          warn "Job '#{job.name}' has #{direction}_type Object, which is too generic. " \
               "Consider using a more specific type for better validation."
        end

        # Check if type is BasicObject (even more generic)
        if type == BasicObject
          raise TypeError, type_declaration_error(job, direction,
                                                  "#{type} is too generic to be useful",
                                                  "Use a specific class like String or Hash")
        end

        true
      end

      # Check type compatibility between connected jobs.
      # Validates that output type of producer matches input type of consumer.
      # Skips jobs with multiple dependencies (using inputs_from_multiple).
      # Skips jobs using inputs_from_workflow (they use workflow input, not dependency output).
      #
      # @return [Hash] Compatibility report with any issues found
      def check_compatibility_between_jobs
        issues = []

        @jobs.each do |consumer_job|
          # Skip type checking for jobs with multiple dependencies
          # These jobs use inputs_from_multiple to explicitly map outputs
          next if consumer_job.dependencies.size > 1

          # Skip type checking for jobs using inputs_from_workflow
          # These jobs use the workflow's input type, not their dependency's output type
          next if consumer_job.input_mappings.key?(:workflow)

          consumer_job.dependencies.each do |producer_name|
            producer_job = find_job(producer_name)
            next unless producer_job

            # Check if both have type declarations
            if producer_job.output_type && consumer_job.input_type
              # Check if types are compatible
              unless types_compatible?(producer_job.output_type, consumer_job.input_type)
                issues << {
                  producer: producer_job.name,
                  consumer: consumer_job.name,
                  producer_type: producer_job.output_type,
                  consumer_type: consumer_job.input_type,
                  suggestion: suggest_type_fix(producer_job.output_type, consumer_job.input_type)
                }
              end
            end
          end
        end

        issues
      end

      private

      # Find a job by name.
      #
      # @param name [String] Job name
      # @return [Job, nil] The job or nil if not found
      def find_job(name)
        @jobs.find { |j| j.name == name }
      end

      # Check if two types are compatible.
      # For now, we use a simple check: output type should be a subclass of input type
      # or they should be the same class.
      #
      # @param output_type [Class] The producer's output type
      # @param input_type [Class] The consumer's input type
      # @return [Boolean] true if types are compatible
      def types_compatible?(output_type, input_type)
        # Same type is always compatible
        return true if output_type == input_type

        # Output type is a subclass of input type (covariance)
        return true if output_type < input_type

        # Input type is Object (accepts anything)
        return true if input_type == Object

        # Special case: Numeric and Integer/Float are compatible
        return true if numeric_compatibility?(output_type, input_type)

        false
      end

      # Check for numeric type compatibility.
      #
      # @param output_type [Class] The producer's output type
      # @param input_type [Class] The consumer's input type
      # @return [Boolean] true if numerically compatible
      def numeric_compatibility?(output_type, input_type)
        # Integer is compatible with Numeric
        return true if output_type == Integer && input_type == Numeric

        # Float is compatible with Numeric
        return true if output_type == Float && input_type == Numeric

        false
      end

      # Suggest a fix for type incompatibility.
      #
      # @param output_type [Class] The producer's output type
      # @param input_type [Class] The consumer's input type
      # @return [String] Suggestion message
      def suggest_type_fix(output_type, input_type)
        # Find common ancestor
        common_ancestor = find_common_ancestor(output_type, input_type)

        if common_ancestor
          "Consider using #{common_ancestor.name} as the input type for the consumer, " \
          "or ensure the producer outputs #{input_type.name} instead of #{output_type.name}"
        else
          "The producer's output type (#{output_type.name}) is not compatible with " \
          "the consumer's input type (#{input_type.name}). " \
          "Ensure the producer outputs data that the consumer can process."
        end
      end

      # Find the common ancestor class of two types.
      #
      # @param type1 [Class] First type
      # @param type2 [Class] Second type
      # @return [Class, nil] Common ancestor class or nil
      def find_common_ancestor(type1, type2)
        return type1 if type2 == Object
        return type2 if type1 == Object

        # Get ancestry chains
        type1_ancestors = type1.ancestors
        type2_ancestors = type2.ancestors

        # Find common ancestor
        type1_ancestors.each do |ancestor|
          return ancestor if type2_ancestors.include?(ancestor)
        end

        nil
      end

      # Build a formatted error message for type declaration issues.
      #
      # @param job [Job] The job with the issue
      # @param direction [Symbol] :input or :output
      # @param problem [String] Description of the problem
      # @param suggestion [String] Suggestion for fixing
      # @return [String] Formatted error message
      def type_declaration_error(job, direction, problem, suggestion)
        "Job '#{job.name}' has invalid #{direction}_type declaration:\n" \
        "  Problem: #{problem}\n" \
        "  Suggestion: #{suggestion}"
      end
    end
  end
end
