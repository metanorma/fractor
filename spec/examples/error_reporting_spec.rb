# frozen_string_literal: true

require "fractor/error_reporter"
require "json"
require "socket"

RSpec.describe "Error Reporting Example" do
  # Workers from the example
  class NetworkWorker < Fractor::Worker
    def process(work)
      if work.input[:fail]
        Fractor::WorkResult.new(
          error: SocketError.new("Connection refused"),
          error_code: :connection_refused,
          error_context: { endpoint: work.input[:endpoint], attempt: 1 },
          work: work,
        )
      else
        Fractor::WorkResult.new(result: "Data fetched", work: work)
      end
    end
  end

  class ValidationWorker < Fractor::Worker
    def process(work)
      if work.input[:invalid]
        Fractor::WorkResult.new(
          error: ::ArgumentError.new("Invalid input"),
          error_code: :validation_failed,
          error_context: { field: "email", value: work.input[:value] },
          work: work,
        )
      else
        Fractor::WorkResult.new(result: "Valid", work: work)
      end
    end
  end

  class CriticalWorker < Fractor::Worker
    def process(work)
      if work.input[:critical]
        Fractor::WorkResult.new(
          error: ::SystemStackError.new("Stack overflow"),
          error_severity: :critical,
          error_context: { stack_depth: 10000 },
          work: work,
        )
      else
        Fractor::WorkResult.new(result: "Success", work: work)
      end
    end
  end

  let(:reporter) { Fractor::ErrorReporter.new }
  let(:error_handler_calls) { [] }

  before do
    # Set up error handler similar to the example
    reporter.on_error do |work_result, job_name|
      error_handler_calls << { work_result: work_result, job_name: job_name }
    end
  end

  describe "NetworkWorker" do
    it "processes successful network operations" do
      work = Fractor::Work.new({ endpoint: "api.example.com", id: 1 })
      result = NetworkWorker.new.process(work)

      expect(result).to be_success
      expect(result.result).to eq("Data fetched")
    end

    it "handles network failures with error codes" do
      work = Fractor::Work.new({ fail: true, endpoint: "api.example.com",
                                 id: 1 })
      result = NetworkWorker.new.process(work)

      expect(result).to be_failure
      expect(result.error_code).to eq(:connection_refused)
      expect(result.error).to be_a(SocketError)
      expect(result.error.message).to eq("Connection refused")
    end

    it "includes error context" do
      work = Fractor::Work.new({ fail: true, endpoint: "api.example.com",
                                 id: 1 })
      result = NetworkWorker.new.process(work)

      expect(result.error_context).to eq({ endpoint: "api.example.com",
                                           attempt: 1 })
    end
  end

  describe "ValidationWorker" do
    it "processes valid input successfully" do
      work = Fractor::Work.new({ valid: true, value: "test@example.com" })
      result = ValidationWorker.new.process(work)

      expect(result).to be_success
      expect(result.result).to eq("Valid")
    end

    it "detects invalid input" do
      work = Fractor::Work.new({ invalid: true, value: "bad-email" })
      result = ValidationWorker.new.process(work)

      expect(result).to be_failure
      expect(result.error_code).to eq(:validation_failed)
      expect(result.error).to be_a(ArgumentError)
    end
  end

  describe "CriticalWorker" do
    it "processes normal work successfully" do
      work = Fractor::Work.new({ critical: false })
      result = CriticalWorker.new.process(work)

      expect(result).to be_success
      expect(result.result).to eq("Success")
    end

    it "handles critical errors" do
      work = Fractor::Work.new({ critical: true })
      result = CriticalWorker.new.process(work)

      expect(result).to be_failure
      expect(result.critical?).to be true
      expect(result.error).to be_a(SystemStackError)
    end
  end

  describe "ErrorReporter" do
    describe "recording results" do
      it "records successful operations" do
        work = Fractor::Work.new({ endpoint: "api.example.com" })
        result = NetworkWorker.new.process(work)
        reporter.record(result, job_name: "network_job")

        expect(reporter.total_successes).to eq(1)
        expect(reporter.total_errors).to eq(0)
      end

      it "records failed operations" do
        work = Fractor::Work.new({ fail: true, endpoint: "api.example.com" })
        result = NetworkWorker.new.process(work)
        reporter.record(result, job_name: "network_job")

        expect(reporter.total_errors).to eq(1)
        expect(reporter.total_successes).to eq(0)
      end

      it "calculates overall error rate" do
        # 5 successes
        5.times do |i|
          work = Fractor::Work.new({ endpoint: "api.example.com", id: i })
          result = NetworkWorker.new.process(work)
          reporter.record(result, job_name: "network_job")
        end

        # 3 errors
        3.times do |i|
          work = Fractor::Work.new({ fail: true, endpoint: "api.example.com",
                                     id: i })
          result = NetworkWorker.new.process(work)
          reporter.record(result, job_name: "network_job")
        end

        expect(reporter.total_successes).to eq(5)
        expect(reporter.total_errors).to eq(3)
        expect(reporter.overall_error_rate).to eq(37.5) # 3 / (5 + 3) * 100
      end
    end

    describe "top error categories" do
      before do
        # Network errors (SocketError category)
        3.times do |i|
          work = Fractor::Work.new({ fail: true, endpoint: "api.example.com",
                                     id: i })
          result = NetworkWorker.new.process(work)
          reporter.record(result, job_name: "network_job")
        end

        # Validation errors (ArgumentError category)
        4.times do |i|
          work = Fractor::Work.new({ invalid: true, value: "bad-email-#{i}" })
          result = ValidationWorker.new.process(work)
          reporter.record(result, job_name: "validation_job")
        end

        # Critical error
        work = Fractor::Work.new({ critical: true })
        result = CriticalWorker.new.process(work)
        reporter.record(result, job_name: "critical_job")
      end

      it "identifies top error categories" do
        top = reporter.top_categories

        # Categories are inferred from error types, not class names
        expect(top.keys).to include(:validation, :network)
        expect(top[:validation]).to eq(4) # ArgumentError -> validation
        expect(top[:network]).to eq(3) # SocketError -> network
      end

      it "limits top categories to specified limit" do
        top_2 = reporter.top_categories(limit: 2)

        expect(top_2.size).to eq(2)
        expect(top_2.values.first).to eq(4) # validation with 4 errors
      end
    end

    describe "critical errors" do
      before do
        work = Fractor::Work.new({ critical: true })
        result = CriticalWorker.new.process(work)
        reporter.record(result, job_name: "critical_job")
      end

      it "tracks critical errors separately" do
        critical = reporter.critical_errors

        expect(critical.size).to eq(1)
        expect(critical.first[:category]).to eq(:system) # SystemStackError maps to :system category
        expect(critical.first[:count]).to eq(1)
      end

      it "includes recent critical error details" do
        critical = reporter.critical_errors

        recent = critical.first[:recent]
        expect(recent.size).to eq(1)
        expect(recent.first[:error_class]).to eq("SystemStackError")
        expect(recent.first[:error_severity]).to eq(:critical)
      end
    end

    describe "errors by severity" do
      before do
        # Add various error types
        3.times { reporter.record(Fractor::WorkResult.new(error: StandardError.new("test")), job_name: "test") }
        work = Fractor::Work.new({ critical: true })
        result = CriticalWorker.new.process(work)
        reporter.record(result, job_name: "critical_job")
      end

      it "groups errors by severity level" do
        by_severity = reporter.errors_by_severity

        expect(by_severity[:critical]).to eq(1)
        expect(by_severity[:error]).to eq(3)
      end
    end

    describe "job-specific statistics" do
      before do
        # Network job: 5 success, 3 errors
        5.times do |i|
          work = Fractor::Work.new({ endpoint: "api.example.com", id: i })
          result = NetworkWorker.new.process(work)
          reporter.record(result, job_name: "network_job")
        end
        3.times do |i|
          work = Fractor::Work.new({ fail: true, endpoint: "api.example.com",
                                     id: i })
          result = NetworkWorker.new.process(work)
          reporter.record(result, job_name: "network_job")
        end

        # Validation job: 4 errors
        4.times do |i|
          work = Fractor::Work.new({ invalid: true, value: "bad-email-#{i}" })
          result = ValidationWorker.new.process(work)
          reporter.record(result, job_name: "validation_job")
        end
      end

      it "provides statistics per job" do
        network_stats = reporter.job_stats("network_job")

        expect(network_stats[:total_count]).to eq(3)
        expect(network_stats[:category]).to eq("network_job")
        expect(network_stats[:most_common_code]).to eq(:connection_refused)
        expect(network_stats[:highest_severity]).to eq(:error)
      end

      it "tracks error rate by job" do
        top_jobs = reporter.top_jobs

        expect(top_jobs["network_job"]).to eq(3)
        expect(top_jobs["validation_job"]).to eq(4)
      end
    end

    describe "error handlers" do
      it "triggers error handler on failures" do
        work = Fractor::Work.new({ critical: true })
        result = CriticalWorker.new.process(work)
        reporter.record(result, job_name: "critical_job")

        expect(error_handler_calls.size).to eq(1)
        expect(error_handler_calls.first[:job_name]).to eq("critical_job")
        expect(error_handler_calls.first[:work_result]).to be_critical
      end

      it "does not trigger error handler on successes" do
        work = Fractor::Work.new({ endpoint: "api.example.com" })
        result = NetworkWorker.new.process(work)
        reporter.record(result, job_name: "network_job")

        expect(error_handler_calls.size).to eq(0)
      end
    end

    describe "report generation" do
      before do
        # Add sample data
        5.times do |i|
          work = Fractor::Work.new({ endpoint: "api.example.com", id: i })
          result = NetworkWorker.new.process(work)
          reporter.record(result, job_name: "network_job")
        end
        3.times do |i|
          work = Fractor::Work.new({ fail: true, endpoint: "api.example.com",
                                     id: i })
          result = NetworkWorker.new.process(work)
          reporter.record(result, job_name: "network_job")
        end
      end

      it "generates formatted text report" do
        report = reporter.formatted_report

        expect(report).to include("ERROR REPORT")
        expect(report).to include("Total Errors:")
        expect(report).to include("Total Successes:")
        expect(report).to include("Error Rate:")
      end

      it "generates Prometheus metrics" do
        prometheus = reporter.to_prometheus

        expect(prometheus).to include("# HELP fractor_errors_total")
        expect(prometheus).to include("# TYPE fractor_errors_total counter")
        expect(prometheus).to include("fractor_errors_total 3")
        expect(prometheus).to include("fractor_successes_total 5")
        expect(prometheus).to include("fractor_error_rate")
      end

      it "exports to JSON" do
        json_report = reporter.report
        json_string = reporter.to_json

        # JSON.parse returns string keys, not symbol keys
        parsed_json = JSON.parse(json_string)
        expect(parsed_json["summary"]["total_errors"]).to eq(3)
        expect(parsed_json["summary"]["total_successes"]).to eq(5)
        expect(json_report[:summary][:total_errors]).to eq(3)
        expect(json_report[:summary][:total_successes]).to eq(5)
      end
    end
  end
end
