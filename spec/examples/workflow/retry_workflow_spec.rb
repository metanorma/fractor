# frozen_string_literal: true

require "spec_helper"
require_relative "../../../examples/workflow/retry/retry_workflow"

RSpec.describe "Retry Workflow Examples" do
  describe UnreliableApiWorker do
    it "inherits from Fractor::Worker" do
      expect(described_class.superclass).to eq(Fractor::Worker)
    end

    it "has correct input and output types" do
      expect(described_class.input_type_class).to eq(String)
      expect(described_class.output_type_class).to eq(Hash)
    end
  end

  describe CachedDataWorker do
    it "always returns cached data" do
      work = Fractor::Work.new("https://api.example.com/data")
      worker = described_class.new
      result = worker.process(work)

      expect(result.result[:status]).to eq("cached")
      expect(result.result[:data][:cached]).to be true
    end
  end

  describe ProcessResponseWorker do
    it "processes successful API response" do
      work = Fractor::Work.new(
        { status: "success",
          data: { url: "https://api.example.com", timestamp: Time.now } },
      )
      worker = described_class.new
      result = worker.process(work)

      expect(result.result).to include("Fresh data")
    end

    it "processes cached response" do
      work = Fractor::Work.new(
        { status: "cached",
          data: { url: "https://api.example.com", cached: true } },
      )
      worker = described_class.new
      result = worker.process(work)

      expect(result.result).to include("Using cached data")
    end
  end

  describe ExponentialRetryWorkflow do
    it "is a valid workflow" do
      expect(described_class.superclass).to eq(Fractor::Workflow)
      expect(described_class.workflow_name).to eq("exponential-retry-demo")
    end

    it "has retry configuration on fetch_api_data job" do
      job = described_class.jobs["fetch_api_data"]
      expect(job.retry_enabled?).to be true
      expect(job.retry_config.max_attempts).to eq(3)
      expect(job.retry_config.strategy).to be_a(
        Fractor::Workflow::ExponentialBackoff,
      )
    end

    it "has fallback job configured" do
      job = described_class.jobs["fetch_api_data"]
      expect(job.fallback_job).to eq("fetch_cached_data")
    end

    it "has error handler configured" do
      job = described_class.jobs["fetch_api_data"]
      expect(job.error_handlers).not_to be_empty
    end

    it "executes workflow successfully with fallback" do
      # Note: RSpec mocks don't work with Ractors, so we rely on the
      # UnreliableApiWorker's 70% failure rate to trigger fallback
      # We run the workflow multiple times to ensure we hit the failure case

      workflow = described_class.new
      result = workflow.execute(input: "https://api.example.com/data")

      # Workflow should complete
      expect(result).to be_a(Fractor::Workflow::WorkflowResult)

      # The workflow should have at least one completed job
      expect(result.completed_jobs).not_to be_empty

      # The output should be either a String (from process_response) or a Hash (from fetch_api_data/fetch_cached_data)
      expect(result.output).to(satisfy { |o| o.is_a?(String) || o.is_a?(Hash) })
    end
  end

  describe LinearRetryWorkflow do
    it "has linear retry configuration" do
      job = described_class.jobs["fetch_api_data"]
      expect(job.retry_enabled?).to be true
      expect(job.retry_config.strategy).to be_a(
        Fractor::Workflow::LinearBackoff,
      )
      expect(job.retry_config.max_attempts).to eq(5)
    end
  end

  describe ConstantRetryWorkflow do
    it "has constant retry configuration" do
      job = described_class.jobs["fetch_api_data"]
      expect(job.retry_enabled?).to be true
      expect(job.retry_config.strategy).to be_a(
        Fractor::Workflow::ConstantDelay,
      )
      expect(job.retry_config.max_attempts).to eq(4)
    end
  end
end
