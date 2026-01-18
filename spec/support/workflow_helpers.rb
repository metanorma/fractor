# frozen_string_literal: true

module Fractor
  # Testing helpers for Workflow specs
  module WorkflowHelpers
    # Creates a simple mock worker for testing
    #
    # @param name [String] Name for the worker class
    # @param behavior [Proc] The processing behavior
    # @return [Class] A Worker subclass
    def self.create_mock_worker(name, behavior: ->(work) {
      WorkResult.new(result: work.input, work: work)
    })
      Class.new(Fractor::Worker) do
        define_singleton_method(:to_s) { name }
        define_singleton_method(:inspect) { name }

        define_method(:process) do |work|
          behavior.call(work)
        end
      end
    end

    # Creates a worker that returns a successful result
    #
    # @param result_value [Object] The value to return
    # @return [Class] A Worker subclass
    def self.success_worker(result_value = :success)
      create_mock_worker("SuccessWorker", ->(work) {
        WorkResult.new(result: result_value, work: work)
      })
    end

    # Creates a worker that returns an error result
    #
    # @param error_message [String] The error message
    # @return [Class] A Worker subclass
    def self.error_worker(error_message = "Test error")
      create_mock_worker("ErrorWorker", ->(work) {
        error = StandardError.new(error_message)
        WorkResult.new(error: error, work: work)
      })
    end

    # Creates a worker that transforms data
    #
    # @param transformer [Proc] The transformation function
    # @return [Class] A Worker subclass
    def self.transform_worker(transformer)
      create_mock_worker("TransformWorker", ->(work) {
        result = transformer.call(work.input)
        WorkResult.new(result: result, work: work)
      })
    end

    # Creates a test workflow with the given jobs
    #
    # @param name [String] Workflow name
    # @param jobs [Hash] Job configuration (name => worker class)
    # @param mode [Symbol] :pipeline or :continuous
    # @return [Class] A Workflow subclass
    def self.create_test_workflow(name:, jobs:, mode: :pipeline)
      Fractor::Workflow.define(name, mode: mode) do
        jobs.each do |job_name, worker_class|
          job job_name.to_s, worker_class
        end
      end
    end

    # Creates a linear chain workflow for testing
    #
    # @param name [String] Workflow name
    # @param workers [Array<Class>] Array of worker classes
    # @return [Class] A Workflow subclass
    def self.create_linear_workflow(name:, workers:)
      # Use ChainBuilder.define for consistency with Workflow.define pattern
      Fractor::Workflow::ChainBuilder.define(name) do |chain|
        workers.each_with_index do |worker, index|
          chain.step("step#{index + 1}", worker)
        end
      end
    end

    # Creates test work items
    #
    # @param data [Object] The work data
    # @return [Work] A Work instance
    def self.create_test_work(data = :test_data)
      TestWork.new(data)
    end

    # Test Work class for use in specs
    class TestWork < Fractor::Work
      def initialize(data)
        super({ data: data })
      end

      def data
        input[:data]
      end
    end

    # Matchers for workflow execution results
    module Matchers
      # Matcher for successful workflow execution
      #
      # @example
      #   expect(result).to be_a_success
      def be_a_success
        RSpec::Matchers::BuiltIn::BeA.new(Fractor::Workflow::WorkResult::Success)
      end

      # Matcher for failed workflow execution
      #
      # @example
      #   expect(result).to be_a_failure
      def be_a_failure
        RSpec::Matchers::BuiltIn::BeA.new(Fractor::Workflow::WorkResult::Failure)
      end

      # Matcher for workflow completion
      #
      # @example
      #   expect(result).to be_completed
      def be_completed
        RSpec::Matchers::Matcher.new :be_completed do
          match { |result| result.is_a?(Fractor::Workflow::WorkResult) && result.success? }

          failure_message do |result|
            "expected workflow to be completed, but got: #{result.inspect}"
          end
        end
      end

      # Matcher for workflow having processed specific jobs
      #
      # @param job_names [Array<String>] Expected job names
      # @example
      #   expect(result).to have_processed_jobs(["job1", "job2"])
      def have_processed_jobs(job_names)
        RSpec::Matchers::Matcher.new :have_processed_jobs, job_names do
          match do |result|
            result.is_a?(Fractor::Workflow::WorkResult) &&
              result.execution_trace &&
              job_names.all? do |name|
                result.execution_trace.any? do |event|
                  event[:job] == name
                end
              end
          end

          failure_message do |result|
            "expected workflow to have processed jobs #{job_names.inspect}, " \
            "but got: #{result.execution_trace&.map do |e|
              e[:job]
            end&.inspect || 'no trace'}"
          end
        end
      end
    end

    # Helper methods for workflow validation
    module ValidationHelpers
      # Validates that a workflow has valid job dependencies
      #
      # @param workflow [Class] Workflow class
      # @return [Boolean] true if valid
      def self.valid_dependencies?(workflow)
        validator = Fractor::Workflow::WorkflowValidator.new(workflow)
        validator.validate
        validator.errors.empty?
      end

      # Gets validation errors for a workflow
      #
      # @param workflow [Class] Workflow class
      # @return [Array<String>] Array of error messages
      def self.validation_errors(workflow)
        validator = Fractor::Workflow::WorkflowValidator.new(workflow)
        validator.validate
        validator.errors
      end
    end

    # Helper to execute workflow with timeout
    #
    # @param workflow [Fractor::Workflow] Workflow instance
    # @param input [Hash] Input data
    # @param timeout [Integer] Timeout in seconds
    # @return [Fractor::Workflow::WorkResult] Execution result
    def self.execute_with_timeout(workflow, input:, timeout: 5)
      Timeout.timeout(timeout) do
        workflow.execute(input: input)
      end
    rescue Timeout::Error
      raise "Workflow execution timed out after #{timeout} seconds"
    end
  end
end

# Configure RSpec to include workflow helpers
RSpec.configure do |config|
  config.include Fractor::WorkflowHelpers::Matchers
  config.extend Fractor::WorkflowHelpers::Matchers, type: :workflow
end
