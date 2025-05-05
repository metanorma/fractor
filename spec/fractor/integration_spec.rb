# frozen_string_literal: true

require 'timeout'

RSpec.describe "Fractor Integration" do
  # Define test classes based on sample.rb
  class MyWorker < Fractor::Worker
    def process(work)
      if work.input == 5
        # Return a Fractor::WorkResult for errors
        return Fractor::WorkResult.new(error: "Error processing work #{work.input}", work: work)
      end

      calculated = work.input * 2
      # Return a Fractor::WorkResult for success
      Fractor::WorkResult.new(result: calculated, work: work)
    end
  end

  class MyWork < Fractor::Work
    def to_s
      "MyWork: #{@input}"
    end
  end

  it "processes work items in parallel as shown in the sample" do
    # Create supervisor
    supervisor = Fractor::Supervisor.new(
      worker_class: MyWorker,
      work_class: MyWork,
      num_workers: 2
    )

    # Add work items (1..10)
    work_items = (1..10).to_a
    supervisor.add_work(work_items)

    # Run the supervisor with a reasonable timeout
    Timeout.timeout(15) do
      supervisor.run
    end

    # Verify all work was processed
    processed_count = supervisor.results.results.size + supervisor.results.errors.size
    expect(processed_count).to eq(10)

    # Verify success results
    success_results = supervisor.results.results
    expect(success_results.size).to eq(9) # All except item with value 5

    # Check that successful results have the expected values (input * 2)
    success_results.each do |result|
      input = result.work.input
      expect(input).not_to eq(5) # Should not include the error case
      expect(result.result).to eq(input * 2)
    end

    # Verify error result
    error_results = supervisor.results.errors
    expect(error_results.size).to eq(1)
    expect(error_results.first.work.input).to eq(5)
    expect(error_results.first.error).to eq("Error processing work 5")
  end
end
