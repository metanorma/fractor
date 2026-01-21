#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "../../../lib/fractor"

# Input and output data types
class NumberInput
  attr_accessor :value

  def initialize(value: 0)
    @value = value
  end
end

class ValidationResult
  attr_accessor :is_positive, :is_even

  def initialize(is_positive: false, is_even: false)
    @is_positive = is_positive
    @is_even = is_even
  end
end

class ProcessedNumber
  attr_accessor :result, :operation

  def initialize(result: 0, operation: "")
    @result = result
    @operation = operation
  end
end

module ConditionalExample
  # Enable/disable debug output from workers
  @debug_output = false

  class << self
    attr_accessor :debug_output
  end

  # Worker that validates the number
  class ValidatorWorker < Fractor::Worker
    input_type NumberInput
    output_type ValidationResult

    def process(work)
      input = work.input
      puts "[Validator] Checking number: #{input.value}" if ConditionalExample.debug_output

      output = ValidationResult.new(
        is_positive: input.value > 0,
        is_even: input.value.even?,
      )

      puts "[Validator] Positive: #{output.is_positive}, Even: #{output.is_even}" if ConditionalExample.debug_output
      Fractor::WorkResult.new(result: output, work: work)
    end
  end

  # Worker that doubles positive numbers
  class DoubleWorker < Fractor::Worker
    input_type NumberInput
    output_type ProcessedNumber

    def process(work)
      input = work.input
      result = input.value * 2
      puts "[DoubleWorker] Doubled #{input.value} to #{result}" if ConditionalExample.debug_output

      output = ProcessedNumber.new(
        result: result,
        operation: "doubled",
      )

      Fractor::WorkResult.new(result: output, work: work)
    end
  end

  # Worker that squares even numbers
  class SquareWorker < Fractor::Worker
    input_type NumberInput
    output_type ProcessedNumber

    def process(work)
      input = work.input
      result = input.value**2
      puts "[SquareWorker] Squared #{input.value} to #{result}" if ConditionalExample.debug_output

      output = ProcessedNumber.new(
        result: result,
        operation: "squared",
      )

      Fractor::WorkResult.new(result: output, work: work)
    end
  end

  # Worker that returns original for non-positive, non-even numbers
  class PassThroughWorker < Fractor::Worker
    input_type NumberInput
    output_type ProcessedNumber

    def process(work)
      input = work.input
      puts "[PassThrough] Keeping original value: #{input.value}" if ConditionalExample.debug_output

      output = ProcessedNumber.new(
        result: input.value,
        operation: "unchanged",
      )

      Fractor::WorkResult.new(result: output, work: work)
    end
  end
end

# Define the conditional workflow
class ConditionalWorkflow < Fractor::Workflow
  workflow "conditional_example" do
    input_type NumberInput
    output_type ProcessedNumber

    # Define workflow start and end
    start_with "validate"
    end_with "double", on: :success
    end_with "square", on: :success
    end_with "passthrough", on: :success

    # Job 1: Validate the number
    job "validate" do
      runs_with ConditionalExample::ValidatorWorker
      inputs_from_workflow
    end

    # Job 2: Double if positive (conditional)
    job "double" do
      runs_with ConditionalExample::DoubleWorker
      needs "validate"
      inputs_from_workflow
      if_condition ->(context) {
        validation = context.job_output("validate")
        validation.is_positive
      }
      outputs_to_workflow
      terminates_workflow
    end

    # Job 3: Square if even (conditional)
    job "square" do
      runs_with ConditionalExample::SquareWorker
      needs "validate"
      inputs_from_workflow
      if_condition ->(context) {
        validation = context.job_output("validate")
        validation.is_even && !validation.is_positive
      }
      outputs_to_workflow
      terminates_workflow
    end

    # Job 4: Pass through if neither positive nor even (conditional)
    job "passthrough" do
      runs_with ConditionalExample::PassThroughWorker
      needs "validate"
      inputs_from_workflow
      if_condition ->(context) {
        validation = context.job_output("validate")
        !validation.is_positive && !validation.is_even
      }
      outputs_to_workflow
      terminates_workflow
    end
  end
end

# Only run the example when this file is executed directly
if __FILE__ == $PROGRAM_NAME
  # Execute the workflow with different inputs
  puts "=" * 60
  puts "Conditional Workflow Example"
  puts "=" * 60
  puts ""

  # Enable debug output for demonstration
  ConditionalExample.debug_output = true

  test_cases = [
    { value: 5, description: "Positive number (should double)" },
    { value: -4, description: "Negative even number (should square)" },
    { value: -3, description: "Negative odd number (should pass through)" },
  ]

  test_cases.each_with_index do |test_case, index|
    puts "Test Case #{index + 1}: #{test_case[:description]}"
    puts "-" * 60

    input = NumberInput.new(value: test_case[:value])
    puts "Input: #{input.value}"
    puts ""

    workflow = ConditionalWorkflow.new
    result = workflow.execute(input: input)

    puts ""
    puts "Results:"
    puts "  Status: #{result.success? ? 'SUCCESS' : 'FAILED'}"
    puts "  Execution Time: #{result.execution_time.round(3)}s"
    puts "  Completed Jobs: #{result.completed_jobs.join(', ')}"
    puts "  Final Result: #{result.output.result}"
    puts "  Operation: #{result.output.operation}"
    puts ""
    puts "=" * 60
    puts ""
  end
end
