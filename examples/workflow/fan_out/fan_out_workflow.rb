#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "../../../lib/fractor"

# Input and output data types
class TextInput
  attr_accessor :text

  def initialize(text: "")
    @text = text
  end
end

class ProcessedText
  attr_accessor :result

  def initialize(result: "")
    @result = result
  end
end

class CombinedResult
  attr_accessor :uppercase, :lowercase, :reversed

  def initialize(uppercase: "", lowercase: "", reversed: "")
    @uppercase = uppercase
    @lowercase = lowercase
    @reversed = reversed
  end
end

module FanOutExample
  # Enable/disable debug output from workers
  @debug_output = false

  class << self
    attr_accessor :debug_output
  end

  # Worker that splits text for parallel processing
  class TextSplitter < Fractor::Worker
    input_type TextInput
    output_type TextInput

    def process(work)
      input = work.input
      puts "[TextSplitter] Processing: #{input.text}" if FanOutExample.debug_output

      output = TextInput.new(text: input.text)
      Fractor::WorkResult.new(result: output, work: work)
    end
  end

  # Worker that converts to uppercase
  class UppercaseWorker < Fractor::Worker
    input_type TextInput
    output_type ProcessedText

    def process(work)
      input = work.input
      result = input.text.upcase
      puts "[UppercaseWorker] Result: #{result}" if FanOutExample.debug_output

      output = ProcessedText.new(result: result)
      Fractor::WorkResult.new(result: output, work: work)
    end
  end

  # Worker that converts to lowercase
  class LowercaseWorker < Fractor::Worker
    input_type TextInput
    output_type ProcessedText

    def process(work)
      input = work.input
      result = input.text.downcase
      puts "[LowercaseWorker] Result: #{result}" if FanOutExample.debug_output

      output = ProcessedText.new(result: result)
      Fractor::WorkResult.new(result: output, work: work)
    end
  end

  # Worker that reverses the text
  class ReverseWorker < Fractor::Worker
    input_type TextInput
    output_type ProcessedText

    def process(work)
      input = work.input
      result = input.text.reverse
      puts "[ReverseWorker] Result: #{result}" if FanOutExample.debug_output

      output = ProcessedText.new(result: result)
      Fractor::WorkResult.new(result: output, work: work)
    end
  end

  # Worker that combines all results
  class ResultCombiner < Fractor::Worker
    input_type CombinedResult
    output_type CombinedResult

    def process(work)
      input = work.input
      if FanOutExample.debug_output
        puts "[ResultCombiner] Combining results:"
        puts "  Uppercase: #{input.uppercase}"
        puts "  Lowercase: #{input.lowercase}"
        puts "  Reversed: #{input.reversed}"
      end

      Fractor::WorkResult.new(result: input, work: work)
    end
  end
end

# Define the fan-out workflow
class FanOutWorkflow < Fractor::Workflow
  workflow "fan_out_example" do
    input_type TextInput
    output_type CombinedResult

    # Define workflow start and end
    start_with "split"
    end_with "combine"

    # Entry point: splits text
    job "split" do
      runs_with FanOutExample::TextSplitter
      inputs_from_workflow
    end

    # Fan-out: three jobs processing the same input
    # Note: These jobs could run in parallel but are executed sequentially
    # to avoid Ractor threading complexity in this example
    job "uppercase" do
      runs_with FanOutExample::UppercaseWorker
      needs "split"
      inputs_from_job "split"
    end

    job "lowercase" do
      runs_with FanOutExample::LowercaseWorker
      needs "split"
      inputs_from_job "split"
    end

    job "reverse" do
      runs_with FanOutExample::ReverseWorker
      needs "split"
      inputs_from_job "split"
    end

    # Fan-in: combine results from all jobs
    job "combine" do
      runs_with FanOutExample::ResultCombiner
      needs "uppercase", "lowercase", "reverse"
      inputs_from_multiple(
        "uppercase" => { uppercase: :result },
        "lowercase" => { lowercase: :result },
        "reverse" => { reversed: :result }
      )
      outputs_to_workflow
      terminates_workflow
    end
  end
end

# Only run the example when this file is executed directly
if __FILE__ == $PROGRAM_NAME
  # Execute the workflow
  puts "=" * 60
  puts "Fan-Out Workflow Example"
  puts "=" * 60
  puts ""

  # Enable debug output for demonstration
  FanOutExample.debug_output = true

  input = TextInput.new(text: "Hello Fractor!")
  puts "Input: #{input.text}"
  puts ""

  workflow = FanOutWorkflow.new
  result = workflow.execute(input: input)

  puts ""
  puts "=" * 60
  puts "Workflow Results:"
  puts "-" * 60
  puts "Status: #{result.success? ? 'SUCCESS' : 'FAILED'}"
  puts "Execution Time: #{result.execution_time.round(3)}s"
  puts "Completed Jobs: #{result.completed_jobs.join(', ')}"
  puts ""
  puts "Final Output:"
  puts "  Uppercase: #{result.output.uppercase}"
  puts "  Lowercase: #{result.output.lowercase}"
  puts "  Reversed: #{result.output.reversed}"
  puts "=" * 60
end
