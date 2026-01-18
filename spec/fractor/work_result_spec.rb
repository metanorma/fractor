# frozen_string_literal: true

RSpec.describe Fractor::WorkResult do
  let(:sample_work) { Fractor::Work.new("test input") }

  describe "#initialize" do
    it "initializes with a result" do
      result = described_class.new(result: "success", work: sample_work)

      expect(result.result).to eq("success")
      expect(result.error).to be_nil
      expect(result.work).to eq(sample_work)
    end

    it "initializes with an error" do
      result = described_class.new(error: "failed", work: sample_work)

      expect(result.result).to be_nil
      expect(result.error).to eq("failed")
      expect(result.work).to eq(sample_work)
    end

    it "initializes with only required parameters" do
      result = described_class.new

      expect(result.result).to be_nil
      expect(result.error).to be_nil
      expect(result.work).to be_nil
    end
  end

  describe "#success?" do
    it "returns true when no error is present" do
      result = described_class.new(result: "success")
      expect(result.success?).to be true
    end

    it "returns false when an error is present" do
      result = described_class.new(error: "failed")
      expect(result.success?).to be false
    end
  end

  describe "#to_s" do
    it "returns a success message when successful" do
      result = described_class.new(result: "success data")
      expect(result.to_s).to eq("Result: success data")
    end

    it "returns an error message when failed" do
      result = described_class.new(error: "failed", work: sample_work)
      expect(result.to_s).to eq("Error: failed, Code: , Category: unknown, Severity: warning")
    end
  end

  describe "#inspect" do
    it "returns a hash with result for successful results" do
      result = described_class.new(result: "success", work: sample_work)
      inspected = result.inspect

      expect(inspected).to be_a(Hash)
      expect(inspected[:result]).to eq("success")
      expect(inspected[:work]).to eq("Work: test input")
    end

    it "returns a hash with error metadata for failed results" do
      result = described_class.new(
        error: StandardError.new("failed"),
        work: sample_work,
        error_code: :api_timeout,
        error_context: { attempt: 3 },
      )
      inspected = result.inspect

      expect(inspected).to be_a(Hash)
      expect(inspected[:error]).to be_a(StandardError)
      expect(inspected[:error_code]).to eq(:api_timeout)
      expect(inspected[:error_category]).to eq(:unknown)
      expect(inspected[:error_severity]).to eq(:error)
      expect(inspected[:error_context]).to eq({ attempt: 3 })
      expect(inspected[:work]).to eq("Work: test input")
    end

    it "handles nil work safely" do
      result = described_class.new(result: "success", work: nil)
      inspected = result.inspect

      expect(inspected).to be_a(Hash)
      expect(inspected[:work]).to be_nil
    end
  end

  describe "error metadata" do
    it "stores error_code" do
      result = described_class.new(
        error: "failed",
        error_code: :timeout,
      )
      expect(result.error_code).to eq(:timeout)
    end

    it "stores error_context" do
      context = { endpoint: "https://api.example.com", timeout: 30 }
      result = described_class.new(
        error: "failed",
        error_context: context,
      )
      expect(result.error_context).to eq(context)
    end

    it "defaults error_context to empty hash" do
      result = described_class.new(error: "failed")
      expect(result.error_context).to eq({})
    end
  end

  describe "error categorization" do
    it "categorizes ArgumentError as validation" do
      result = described_class.new(error: ArgumentError.new)
      expect(result.error_category).to eq(:validation)
    end

    it "categorizes TypeError as validation" do
      result = described_class.new(error: TypeError.new)
      expect(result.error_category).to eq(:validation)
    end

    it "categorizes Timeout::Error as timeout" do
      result = described_class.new(error: Timeout::Error.new)
      expect(result.error_category).to eq(:timeout)
    end

    it "categorizes SocketError as network" do
      skip "SocketError not defined in this environment" unless defined?(SocketError)

      result = described_class.new(error: SocketError.new("Connection failed"))
      expect(result.error_category).to eq(:network)
    end

    it "categorizes SystemStackError as system" do
      result = described_class.new(error: SystemStackError.new)
      expect(result.error_category).to eq(:system)
    end

    it "categorizes unknown errors as unknown" do
      result = described_class.new(error: RuntimeError.new)
      expect(result.error_category).to eq(:unknown)
    end

    it "allows manual category override" do
      result = described_class.new(
        error: RuntimeError.new,
        error_category: :business,
      )
      expect(result.error_category).to eq(:business)
    end
  end

  describe "error severity" do
    it "categorizes SystemStackError as critical" do
      result = described_class.new(error: SystemStackError.new)
      expect(result.error_severity).to eq(:critical)
    end

    it "categorizes StandardError as error" do
      result = described_class.new(error: StandardError.new)
      expect(result.error_severity).to eq(:error)
    end

    it "allows manual severity override" do
      result = described_class.new(
        error: StandardError.new,
        error_severity: :warning,
      )
      expect(result.error_severity).to eq(:warning)
    end
  end

  describe "#failure?" do
    it "returns true when error is present" do
      result = described_class.new(error: "failed")
      expect(result.failure?).to be true
    end

    it "returns false when no error" do
      result = described_class.new(result: "success")
      expect(result.failure?).to be false
    end
  end

  describe "#critical?" do
    it "returns true for critical severity" do
      result = described_class.new(
        error: StandardError.new,
        error_severity: :critical,
      )
      expect(result.critical?).to be true
    end

    it "returns false for non-critical severity" do
      result = described_class.new(
        error: StandardError.new,
        error_severity: :error,
      )
      expect(result.critical?).to be false
    end
  end

  describe "#retriable?" do
    it "returns true for timeout errors" do
      result = described_class.new(error: Timeout::Error.new)
      expect(result.retriable?).to be true
    end

    it "returns true for network errors" do
      skip "SocketError not defined in this environment" unless defined?(SocketError)

      result = described_class.new(error: SocketError.new(""))
      expect(result.retriable?).to be true
    end

    it "returns false for validation errors" do
      result = described_class.new(error: ArgumentError.new)
      expect(result.retriable?).to be false
    end

    it "returns false for successful results" do
      result = described_class.new(result: "success")
      expect(result.retriable?).to be false
    end
  end

  describe "#error_info" do
    it "returns nil for successful results" do
      result = described_class.new(result: "success")
      expect(result.error_info).to be_nil
    end

    it "returns comprehensive error information" do
      error = StandardError.new("Something went wrong")
      result = described_class.new(
        error: error,
        error_code: :api_error,
        error_context: { endpoint: "/api/data", status: 500 },
      )

      info = result.error_info
      expect(info[:error]).to eq(error)
      expect(info[:error_class]).to eq("StandardError")
      expect(info[:error_message]).to eq("Something went wrong")
      expect(info[:error_code]).to eq(:api_error)
      expect(info[:error_category]).to eq(:unknown)
      expect(info[:error_severity]).to eq(:error)
      expect(info[:error_context]).to eq({ endpoint: "/api/data", status: 500 })
    end
  end
end
