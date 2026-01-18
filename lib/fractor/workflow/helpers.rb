# frozen_string_literal: true

module Fractor
  class Workflow
    # Helper workers that provide common patterns to reduce boilerplate
    module Helpers
      # Simple worker for basic transformations
      # Just implement the transform method
      #
      # Example:
      #   class MyWorker < Fractor::Workflow::Helpers::SimpleWorker
      #     input_type InputData
      #     output_type OutputData
      #
      #     def transform(input)
      #       OutputData.new(result: input.value * 2)
      #     end
      #   end
      class SimpleWorker < Fractor::Worker
        def process(work)
          input = work.input
          output = transform(input)
          Fractor::WorkResult.new(result: output, work: work)
        end

        # Override this method in subclasses
        def transform(input)
          raise NotImplementedError, "Subclasses must implement #transform"
        end
      end

      # Worker for mapping over collections
      # Implement the map_item method
      #
      # Example:
      #   class ProcessItems < Fractor::Workflow::Helpers::MapWorker
      #     def map_item(item)
      #       item.upcase
      #     end
      #   end
      class MapWorker < Fractor::Worker
        def process(work)
          input = work.input
          collection = extract_collection(input)

          mapped = collection.map { |item| map_item(item) }
          output = build_output(mapped, input)

          Fractor::WorkResult.new(result: output, work: work)
        end

        # Override in subclasses to define how to map each item
        def map_item(item)
          raise NotImplementedError, "Subclasses must implement #map_item"
        end

        # Override to specify how to extract collection from input
        # Default: assumes input responds to :to_a
        def extract_collection(input)
          input.respond_to?(:to_a) ? input.to_a : [input]
        end

        # Override to specify how to build output from mapped collection
        # Default: returns the array
        def build_output(mapped_collection, _original_input)
          mapped_collection
        end
      end

      # Worker for filtering collections
      # Implement the filter_item? method
      #
      # Example:
      #   class FilterPositive < Fractor::Workflow::Helpers::FilterWorker
      #     def filter_item?(item)
      #       item > 0
      #     end
      #   end
      class FilterWorker < Fractor::Worker
        def process(work)
          input = work.input
          collection = extract_collection(input)

          filtered = collection.select { |item| filter_item?(item) }
          output = build_output(filtered, input)

          Fractor::WorkResult.new(result: output, work: work)
        end

        # Override in subclasses to define filter logic
        def filter_item?(item)
          raise NotImplementedError, "Subclasses must implement #filter_item?"
        end

        # Override to specify how to extract collection from input
        def extract_collection(input)
          input.respond_to?(:to_a) ? input.to_a : [input]
        end

        # Override to specify how to build output from filtered collection
        def build_output(filtered_collection, _original_input)
          filtered_collection
        end
      end

      # Worker for reducing/aggregating collections
      # Implement the reduce_items method
      #
      # Example:
      #   class SumNumbers < Fractor::Workflow::Helpers::ReduceWorker
      #     def reduce_items(collection)
      #       collection.sum
      #     end
      #   end
      class ReduceWorker < Fractor::Worker
        def process(work)
          input = work.input
          collection = extract_collection(input)

          result = reduce_items(collection)
          output = build_output(result, input)

          Fractor::WorkResult.new(result: output, work: work)
        end

        # Override in subclasses to define reduce logic
        def reduce_items(collection)
          raise NotImplementedError, "Subclasses must implement #reduce_items"
        end

        # Override to specify how to extract collection from input
        def extract_collection(input)
          input.respond_to?(:to_a) ? input.to_a : [input]
        end

        # Override to specify how to build output from reduced value
        def build_output(reduced_value, _original_input)
          reduced_value
        end
      end

      # Worker for validation
      # Implement the validate method
      #
      # Example:
      #   class ValidateAge < Fractor::Workflow::Helpers::ValidationWorker
      #     def validate(input)
      #       return unless input.age < 0
      #       add_error("Age must be positive")
      #     end
      #   end
      class ValidationWorker < Fractor::Worker
        def initialize
          super
          @errors = []
        end

        def process(work)
          input = work.input
          @errors = []

          validate(input)

          output = build_output(input, @errors)
          Fractor::WorkResult.new(result: output, work: work)
        end

        # Override in subclasses to define validation logic
        # Use add_error(message) to record errors
        def validate(input)
          raise NotImplementedError, "Subclasses must implement #validate"
        end

        # Add a validation error
        def add_error(message)
          @errors << message
        end

        # Override to customize output format
        # Default: returns hash with valid? flag and errors
        def build_output(input, errors)
          {
            valid: errors.empty?,
            errors: errors,
            input: input,
          }
        end
      end
    end
  end
end
