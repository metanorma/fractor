# frozen_string_literal: true

module Fractor
  class Workflow
    # Fluent API for building linear chain workflows.
    # Simplifies creation of sequential processing pipelines.
    #
    # @example Using chain builder
    #   workflow = Fractor::Workflow.chain("text-pipeline")
    #     .step("uppercase", UppercaseWorker)
    #     .step("reverse", ReverseWorker)
    #     .step("finalize", FinalizeWorker)
    #     .build
    #
    #   instance = workflow.new
    #   result = instance.execute(input: data)
    #
    # @example Using define class method
    #   workflow = Fractor::Workflow::ChainBuilder.define("text-pipeline") do |chain|
    #     chain.step("uppercase", UppercaseWorker)
    #     chain.step("reverse", ReverseWorker)
    #     chain.step("finalize", FinalizeWorker)
    #   end
    class ChainBuilder
      attr_reader :name, :steps

      # Define a chain workflow using a block.
      # This is a convenience method that creates and builds a ChainBuilder.
      #
      # @param name [String] The workflow name
      # @yield [ChainBuilder] Block that receives the chain builder
      # @return [Class] A new Workflow subclass
      #
      # @example
      #   workflow = Fractor::Workflow::ChainBuilder.define("my-chain") do |chain|
      #     chain.step("process", MyWorker)
      #     chain.step("finalize", FinalizeWorker)
      #   end
      def self.define(name, &block)
        builder = new(name)
        builder.instance_eval(&block) if block
        builder.build
      end

      def initialize(name)
        @name = name
        @steps = []
        @input_type_class = nil
        @output_type_class = nil
      end

      # Set the input type for the workflow
      #
      # @param klass [Class] The input type class
      # @return [ChainBuilder] self for chaining
      def input_type(klass)
        @input_type_class = klass
        self
      end

      # Set the output type for the workflow
      #
      # @param klass [Class] The output type class
      # @return [ChainBuilder] self for chaining
      def output_type(klass)
        @output_type_class = klass
        self
      end

      # Add a step to the chain
      #
      # @param name [String, Symbol] The step name
      # @param worker [Class] The worker class for this step
      # @param workers [Integer] Optional number of parallel workers
      # @param condition [Proc] Optional conditional execution
      # @return [ChainBuilder] self for chaining
      def step(name, worker, workers: nil, condition: nil)
        step_config = {
          name: name.to_s,
          worker: worker,
          workers: workers,
          condition: condition,
        }
        @steps << step_config
        self
      end

      # Build the workflow class
      #
      # @return [Class] A new Workflow subclass
      def build
        chain_name = @name
        chain_steps = @steps.dup
        chain_input_type = @input_type_class
        chain_output_type = @output_type_class

        Class.new(Workflow) do
          workflow chain_name do
            input_type chain_input_type if chain_input_type
            output_type chain_output_type if chain_output_type

            # Build jobs sequentially
            chain_steps.each_with_index do |step_config, index|
              step_name = step_config[:name]
              step_worker = step_config[:worker]
              step_workers = step_config[:workers]
              step_condition = step_config[:condition]

              # Determine dependencies
              needs_job = index.positive? ? chain_steps[index - 1][:name] : nil

              job step_name, step_worker,
                  needs: needs_job,
                  workers: step_workers,
                  condition: step_condition
            end
          end
        end
      end

      # Validate and build in one step
      #
      # @return [Class] A new Workflow subclass
      # @raise [ArgumentError] if the chain is invalid
      def build!
        validate!
        build
      end

      # Validate the chain configuration
      #
      # @raise [ArgumentError] if validation fails
      def validate!
        if @name.nil? || @name.empty?
          raise ArgumentError,
                "Chain must have a name"
        end

        if @steps.empty?
          raise ArgumentError,
                "Chain must have at least one step"
        end

        # Check for duplicate step names
        step_names = @steps.map { |s| s[:name] }
        duplicates = step_names.select { |n| step_names.count(n) > 1 }.uniq
        if duplicates.any?
          raise ArgumentError,
                "Duplicate step names: #{duplicates.join(', ')}"
        end

        # Validate workers
        @steps.each do |step_config|
          unless step_config[:worker]
            raise ArgumentError,
                  "Step '#{step_config[:name]}' must specify a worker class"
          end

          unless step_config[:worker] < Fractor::Worker
            raise ArgumentError,
                  "Step '#{step_config[:name]}' worker must inherit from Fractor::Worker"
          end
        end

        true
      end
    end
  end
end
