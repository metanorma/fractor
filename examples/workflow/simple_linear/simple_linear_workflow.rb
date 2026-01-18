# frozen_string_literal: true

require_relative "../../../lib/fractor"

# This example demonstrates a simple linear workflow with three sequential jobs.
# Each job processes data and passes it to the next job.

# ============================================
# DATA MODELS
# ============================================

module SimpleLinear
  # Simple data models (in production, use Lutaml::Model::Serializable)
  class TextData
  attr_accessor :text

  def initialize(text:)
    @text = text
  end
end

  class UppercaseOutput
  attr_accessor :uppercased_text, :char_count

  def initialize(uppercased_text:, char_count:)
    @uppercased_text = uppercased_text
    @char_count = char_count
  end
end

  class ReversedOutput
  attr_accessor :reversed_text, :word_count

  def initialize(reversed_text:, word_count:)
    @reversed_text = reversed_text
    @word_count = word_count
  end
end

  class FinalOutput
  attr_accessor :result, :total_operations

  def initialize(result:, total_operations:)
    @result = result
    @total_operations = total_operations
  end
end
end

# ============================================
# WORKERS
# ============================================

module SimpleLinearExample
  class UppercaseWorker < Fractor::Worker
    input_type SimpleLinear::TextData
    output_type SimpleLinear::UppercaseOutput

    def process(work)
      input = work.input
      uppercased = input.text.upcase

      output = SimpleLinear::UppercaseOutput.new(
        uppercased_text: uppercased,
        char_count: uppercased.length,
      )

      Fractor::WorkResult.new(result: output, work: work)
    end
  end

  class ReverseWorker < Fractor::Worker
    input_type SimpleLinear::UppercaseOutput
    output_type SimpleLinear::ReversedOutput

    def process(work)
      input = work.input
      reversed = input.uppercased_text.reverse

      output = SimpleLinear::ReversedOutput.new(
        reversed_text: reversed,
        word_count: reversed.split.size,
      )

      Fractor::WorkResult.new(result: output, work: work)
    end
  end

  class FinalizeWorker < Fractor::Worker
    input_type SimpleLinear::ReversedOutput
    output_type SimpleLinear::FinalOutput

    def process(work)
      input = work.input

      output = SimpleLinear::FinalOutput.new(
        result: input.reversed_text,
        total_operations: 3,
      )

      Fractor::WorkResult.new(result: output, work: work)
    end
  end
end

# ============================================
# WORKFLOW DEFINITION
# ============================================

class SimpleLinearWorkflow < Fractor::Workflow
  workflow "simple-linear" do
    # Define workflow input and output types
    input_type SimpleLinear::TextData
    output_type SimpleLinear::FinalOutput

    # Define start and end points
    start_with "uppercase"
    end_with "finalize"

    # Job 1: Uppercase the text
    job "uppercase" do
      runs_with SimpleLinearExample::UppercaseWorker
      inputs_from_workflow
    end

    # Job 2: Reverse the uppercased text
    job "reverse" do
      needs "uppercase"
      runs_with SimpleLinearExample::ReverseWorker
      inputs_from_job "uppercase"
    end

    # Job 3: Finalize the result
    job "finalize" do
      needs "reverse"
      runs_with SimpleLinearExample::FinalizeWorker
      inputs_from_job "reverse"
      outputs_to_workflow
      terminates_workflow
    end
  end
end

# ============================================
# USAGE
# ============================================

if __FILE__ == $PROGRAM_NAME
  puts "Simple Linear Workflow Example"
  puts "=" * 50
  puts

  # Create input
  input = SimpleLinear::TextData.new(text: "hello world from fractor")
  puts "Input: #{input.text}"
  puts

  # Execute workflow
  workflow = SimpleLinearWorkflow.new
  result = workflow.execute(input: input)

  # Display results
  puts "Workflow Results:"
  puts "-" * 50
  puts "Status: #{result.success? ? 'SUCCESS' : 'FAILED'}"
  puts "Execution Time: #{result.execution_time.round(3)}s"
  puts "Completed Jobs: #{result.completed_jobs.join(', ')}"
  puts
  puts "Final Output:"
  puts "  Result: #{result.output.result}"
  puts "  Total Operations: #{result.output.total_operations}"
  puts

  # Expected output: "ROTCARF MORF DLROW OLLEH"
end
