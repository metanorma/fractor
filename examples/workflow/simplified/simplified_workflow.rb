# frozen_string_literal: true

require_relative "../../../lib/fractor"

# This example demonstrates the simplified workflow syntax options:
# 1. Shorthand syntax with auto-wiring
# 2. Workflow.define (no inheritance)
# 3. Chain API for linear workflows

# ============================================
# DATA MODELS
# ============================================

class TextData
  attr_accessor :text

  def initialize(text:)
    @text = text
  end
end

class UppercaseOutput
  attr_accessor :uppercased_text

  def initialize(uppercased_text:)
    @uppercased_text = uppercased_text
  end
end

class ReversedOutput
  attr_accessor :reversed_text

  def initialize(reversed_text:)
    @reversed_text = reversed_text
  end
end

class FinalOutput
  attr_accessor :result

  def initialize(result:)
    @result = result
  end
end

# ============================================
# WORKERS
# ============================================

module SimplifiedExample
  class UppercaseWorker < Fractor::Worker
    input_type TextData
    output_type UppercaseOutput

    def process(work)
      input = work.input
      output = UppercaseOutput.new(uppercased_text: input.text.upcase)
      Fractor::WorkResult.new(result: output, work: work)
    end
  end

  class ReverseWorker < Fractor::Worker
    input_type UppercaseOutput
    output_type ReversedOutput

    def process(work)
      input = work.input
      output = ReversedOutput.new(reversed_text: input.uppercased_text.reverse)
      Fractor::WorkResult.new(result: output, work: work)
    end
  end

  class FinalizeWorker < Fractor::Worker
    input_type ReversedOutput
    output_type FinalOutput

    def process(work)
      input = work.input
      output = FinalOutput.new(result: input.reversed_text)
      Fractor::WorkResult.new(result: output, work: work)
    end
  end
end

# ============================================
# APPROACH 1: SHORTHAND SYNTAX WITH AUTO-WIRING
# ============================================
# Benefits:
# - Reduced boilerplate
# - Auto-infers inputs from dependencies
# - Auto-detects start/end jobs
# - Still uses class inheritance

class ShorthandWorkflow < Fractor::Workflow
  workflow "shorthand-example" do
    # No need for start_with/end_with - auto-detected!
    # No need for inputs_from_* - auto-wired from dependencies!

    job "uppercase", SimplifiedExample::UppercaseWorker
    job "reverse", SimplifiedExample::ReverseWorker, needs: "uppercase"
    job "finalize", SimplifiedExample::FinalizeWorker, needs: "reverse"
  end
end

# ============================================
# APPROACH 2: WORKFLOW.DEFINE (NO INHERITANCE)
# ============================================
# Benefits:
# - No need to create a class
# - Returns workflow class directly
# - Can be stored in variables

SimplifiedWorkflow = Fractor::Workflow.define("simplified-example") do
  job "uppercase", SimplifiedExample::UppercaseWorker
  job "reverse", SimplifiedExample::ReverseWorker, needs: "uppercase"
  job "finalize", SimplifiedExample::FinalizeWorker, needs: "reverse"
end

# ============================================
# APPROACH 3: CHAIN API (FLUENT)
# ============================================
# Benefits:
# - Most concise for linear workflows
# - Fluent/chainable API
# - No explicit dependency management needed

ChainWorkflow = Fractor::Workflow.chain("chain-example")
  .step("uppercase", SimplifiedExample::UppercaseWorker)
  .step("reverse", SimplifiedExample::ReverseWorker)
  .step("finalize", SimplifiedExample::FinalizeWorker)
  .build

# ============================================
# COMPARISON: BEFORE VS AFTER
# ============================================

# BEFORE (Verbose - from simple_linear example):
# class SimpleLinearWorkflow < Fractor::Workflow
#   workflow "simple-linear" do
#     input_type TextData
#     output_type FinalOutput
#     start_with "uppercase"
#     end_with "finalize"
#
#     job "uppercase" do
#       runs_with SimpleLinearExample::UppercaseWorker
#       inputs_from_workflow
#     end
#
#     job "reverse" do
#       needs "uppercase"
#       runs_with SimpleLinearExample::ReverseWorker
#       inputs_from_job "uppercase"
#     end
#
#     job "finalize" do
#       needs "reverse"
#       runs_with SimpleLinearExample::FinalizeWorker
#       inputs_from_job "reverse"
#       outputs_to_workflow
#       terminates_workflow
#     end
#   end
# end

# AFTER (Shorthand):
# class ShorthandWorkflow < Fractor::Workflow
#   workflow "shorthand-example" do
#     job "uppercase", SimplifiedExample::UppercaseWorker
#     job "reverse", SimplifiedExample::ReverseWorker, needs: "uppercase"
#     job "finalize", SimplifiedExample::FinalizeWorker, needs: "reverse"
#   end
# end

# AFTER (Workflow.define):
# SimplifiedWorkflow = Fractor::Workflow.define("simplified-example") do
#   job "uppercase", SimplifiedExample::UppercaseWorker
#   job "reverse", SimplifiedExample::ReverseWorker, needs: "uppercase"
#   job "finalize", SimplifiedExample::FinalizeWorker, needs: "reverse"
# end

# AFTER (Chain API):
# ChainWorkflow = Fractor::Workflow.chain("chain-example")
#   .step("uppercase", SimplifiedExample::UppercaseWorker)
#   .step("reverse", SimplifiedExample::ReverseWorker)
#   .step("finalize", SimplifiedExample::FinalizeWorker)
#   .build

# ============================================
# USAGE
# ============================================

if __FILE__ == $PROGRAM_NAME
  puts "Simplified Workflow Syntax Examples"
  puts "=" * 60
  puts

  input = TextData.new(text: "hello world")

  # Test all three approaches
  [
    ["Shorthand Syntax", ShorthandWorkflow],
    ["Workflow.define", SimplifiedWorkflow],
    ["Chain API", ChainWorkflow],
  ].each do |name, workflow_class|
    puts "#{name}:"
    puts "-" * 60

    workflow = workflow_class.new
    result = workflow.execute(input: input)

    puts "Status: #{result.success? ? 'SUCCESS' : 'FAILED'}"
    puts "Result: #{result.output.result}"
    puts "Jobs: #{result.completed_jobs.join(' → ')}"
    puts
  end

  # Show visualization
  puts "Workflow Diagram (ASCII):"
  puts "-" * 60
  ShorthandWorkflow.print_diagram
end
