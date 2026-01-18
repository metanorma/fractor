# frozen_string_literal: true

require "spec_helper"
require "fractor/error_reporter"
require "fractor/work_result"

RSpec.describe Fractor::ErrorReporter do
  let(:reporter) { described_class.new }

  describe "#initialize" do
    it "initializes with zero errors and successes" do
      expect(reporter.total_errors).to eq(0)
      expect(reporter.total_successes).to eq(0)
    end

    it "sets start_time" do
      expect(reporter.start_time).to be_a(Time)
    end
  end

  describe "#record" do
    context "with successful result" do
      let(:success_result) do
        Fractor::WorkResult.new(result: "success")
      end

      it "increments total_successes" do
        expect { reporter.record(success_result) }
          .to change(reporter, :total_successes).by(1)
      end

      it "does not increment total_errors" do
        expect { reporter.record(success_result) }
          .not_to(change(reporter, :total_errors))
      end
    end

    context "with error result" do
      let(:error_result) do
        Fractor::WorkResult.new(
          error: StandardError.new("Test error"),
          error_code: :test_error,
          error_category: :validation,
          error_severity: :error,
        )
      end

      it "increments total_errors" do
        expect { reporter.record(error_result) }
          .to change(reporter, :total_errors).by(1)
      end

      it "does not increment total_successes" do
        expect { reporter.record(error_result) }
          .not_to(change(reporter, :total_successes))
      end

      it "records error by category" do
        reporter.record(error_result)
        stats = reporter.category_stats(:validation)
        expect(stats).not_to be_nil
        expect(stats[:total_count]).to eq(1)
      end

      it "records error by job when job_name provided" do
        reporter.record(error_result, job_name: "test_job")
        stats = reporter.job_stats("test_job")
        expect(stats).not_to be_nil
        expect(stats[:total_count]).to eq(1)
      end
    end
  end

  describe "#on_error" do
    it "registers error handler" do
      called = false
      reporter.on_error { |_result, _job| called = true }

      error_result = Fractor::WorkResult.new(
        error: StandardError.new("Test"),
      )
      reporter.record(error_result)

      expect(called).to be true
    end

    it "passes work_result and job_name to handler" do
      received_result = nil
      received_job = nil

      reporter.on_error do |result, job|
        received_result = result
        received_job = job
      end

      error_result = Fractor::WorkResult.new(
        error: StandardError.new("Test"),
      )
      reporter.record(error_result, job_name: "my_job")

      expect(received_result).to eq(error_result)
      expect(received_job).to eq("my_job")
    end

    it "continues if handler raises error" do
      reporter.on_error { |_r, _j| raise "Handler error" }

      error_result = Fractor::WorkResult.new(
        error: StandardError.new("Test"),
      )

      expect { reporter.record(error_result) }.not_to raise_error
    end
  end

  describe "#overall_error_rate" do
    it "returns 0 when no work recorded" do
      expect(reporter.overall_error_rate).to eq(0.0)
    end

    it "calculates error rate correctly" do
      3.times do
        reporter.record(Fractor::WorkResult.new(result: "success"))
      end
      2.times do
        reporter.record(Fractor::WorkResult.new(error: StandardError.new("Error")))
      end

      expect(reporter.overall_error_rate).to eq(40.0) # 2/5 * 100
    end
  end

  describe "#errors_by_severity" do
    it "aggregates errors by severity" do
      reporter.record(Fractor::WorkResult.new(
                        error: StandardError.new("Error"),
                        error_severity: :critical,
                      ))
      reporter.record(Fractor::WorkResult.new(
                        error: StandardError.new("Error"),
                        error_severity: :error,
                      ))
      reporter.record(Fractor::WorkResult.new(
                        error: StandardError.new("Error"),
                        error_severity: :error,
                      ))

      by_severity = reporter.errors_by_severity
      expect(by_severity[:critical]).to eq(1)
      expect(by_severity[:error]).to eq(2)
    end
  end

  describe "#top_categories" do
    it "returns top categories by error count" do
      5.times do
        reporter.record(Fractor::WorkResult.new(
                          error: StandardError.new("Error"),
                          error_category: :validation,
                        ))
      end
      3.times do
        reporter.record(Fractor::WorkResult.new(
                          error: StandardError.new("Error"),
                          error_category: :network,
                        ))
      end
      reporter.record(Fractor::WorkResult.new(
                        error: StandardError.new("Error"),
                        error_category: :timeout,
                      ))

      top = reporter.top_categories(limit: 2)
      expect(top.keys).to eq(%i[validation network])
      expect(top[:validation]).to eq(5)
      expect(top[:network]).to eq(3)
    end
  end

  describe "#top_jobs" do
    it "returns top jobs by error count" do
      5.times do
        reporter.record(
          Fractor::WorkResult.new(error: StandardError.new("Error")),
          job_name: "job_a",
        )
      end
      3.times do
        reporter.record(
          Fractor::WorkResult.new(error: StandardError.new("Error")),
          job_name: "job_b",
        )
      end

      top = reporter.top_jobs(limit: 2)
      expect(top.keys).to eq(["job_a", "job_b"])
      expect(top["job_a"]).to eq(5)
      expect(top["job_b"]).to eq(3)
    end
  end

  describe "#critical_errors" do
    it "returns critical errors with recent examples" do
      reporter.record(Fractor::WorkResult.new(
                        error: StandardError.new("Critical error"),
                        error_severity: :critical,
                        error_category: :system,
                      ))

      critical = reporter.critical_errors
      expect(critical).not_to be_empty
      expect(critical.first[:category]).to eq(:system)
      expect(critical.first[:count]).to eq(1)
      expect(critical.first[:recent]).not_to be_empty
    end

    it "returns empty array when no critical errors" do
      reporter.record(Fractor::WorkResult.new(
                        error: StandardError.new("Warning"),
                        error_severity: :warning,
                      ))

      expect(reporter.critical_errors).to be_empty
    end
  end

  describe "#trending_errors" do
    it "detects increasing error rates" do
      # Record 10 errors for same category to establish trend
      15.times do |i|
        reporter.record(Fractor::WorkResult.new(
                          error: StandardError.new("Error #{i}"),
                          error_category: :validation,
                        ))
      end

      trending = reporter.trending_errors
      expect(trending).not_to be_empty
      expect(trending.first[:category]).to eq(:validation)
    end
  end

  describe "#report" do
    before do
      reporter.record(Fractor::WorkResult.new(result: "success"))
      reporter.record(Fractor::WorkResult.new(
                        error: StandardError.new("Error"),
                        error_severity: :critical,
                        error_category: :validation,
                      ))
    end

    it "includes summary section" do
      report = reporter.report
      expect(report[:summary]).to include(
        :uptime,
        :total_errors,
        :total_successes,
        :error_rate,
        :errors_by_severity,
      )
    end

    it "includes top_categories" do
      report = reporter.report
      expect(report[:top_categories]).not_to be_empty
    end

    it "includes top_jobs" do
      report = reporter.report
      expect(report).to have_key(:top_jobs)
    end

    it "includes critical_errors" do
      report = reporter.report
      expect(report[:critical_errors]).not_to be_empty
    end

    it "includes category_breakdown" do
      report = reporter.report
      expect(report[:category_breakdown]).to have_key(:validation)
    end
  end

  describe "#formatted_report" do
    before do
      reporter.record(Fractor::WorkResult.new(result: "success"))
      reporter.record(Fractor::WorkResult.new(
                        error: StandardError.new("Test error"),
                        error_category: :validation,
                      ))
    end

    it "returns formatted text report" do
      report = reporter.formatted_report
      expect(report).to include("ERROR REPORT")
      expect(report).to include("SUMMARY")
      expect(report).to include("TOP ERROR CATEGORIES")
    end

    it "includes error statistics" do
      report = reporter.formatted_report
      expect(report).to include("Total Errors")
      expect(report).to include("Total Successes")
      expect(report).to include("Error Rate")
    end
  end

  describe "#to_prometheus" do
    before do
      reporter.record(Fractor::WorkResult.new(result: "success"))
      reporter.record(Fractor::WorkResult.new(
                        error: StandardError.new("Error"),
                        error_severity: :critical,
                      ))
    end

    it "exports Prometheus format" do
      prometheus = reporter.to_prometheus
      expect(prometheus).to include("fractor_errors_total")
      expect(prometheus).to include("fractor_successes_total")
      expect(prometheus).to include("fractor_error_rate")
      expect(prometheus).to include("fractor_errors_by_severity")
      expect(prometheus).to include("fractor_errors_by_category")
    end

    it "includes HELP and TYPE metadata" do
      prometheus = reporter.to_prometheus
      expect(prometheus).to include("# HELP")
      expect(prometheus).to include("# TYPE")
    end
  end

  describe "#to_json" do
    before do
      reporter.record(Fractor::WorkResult.new(result: "success"))
    end

    it "exports JSON format" do
      json = reporter.to_json
      expect(json).to be_a(String)
      parsed = JSON.parse(json)
      expect(parsed).to have_key("summary")
    end
  end

  describe "#reset" do
    before do
      reporter.record(Fractor::WorkResult.new(result: "success"))
      reporter.record(Fractor::WorkResult.new(
                        error: StandardError.new("Error"),
                      ))
    end

    it "resets all statistics" do
      reporter.reset

      expect(reporter.total_errors).to eq(0)
      expect(reporter.total_successes).to eq(0)
      expect(reporter.top_categories).to be_empty
    end

    it "updates start_time" do
      old_time = reporter.start_time
      sleep 0.01
      reporter.reset
      expect(reporter.start_time).to be > old_time
    end
  end

  describe Fractor::ErrorStatistics do
    let(:stats) { described_class.new(:validation) }

    describe "#record" do
      it "tracks total count" do
        result = Fractor::WorkResult.new(
          error: StandardError.new("Error"),
          error_code: :invalid,
        )

        expect { stats.record(result) }
          .to change(stats, :total_count).by(1)
      end

      it "tracks errors by severity" do
        result = Fractor::WorkResult.new(
          error: StandardError.new("Error"),
          error_severity: :critical,
        )

        stats.record(result)
        expect(stats.by_severity[:critical]).to eq(1)
      end

      it "tracks errors by code" do
        result = Fractor::WorkResult.new(
          error: StandardError.new("Error"),
          error_code: :invalid_input,
        )

        stats.record(result)
        expect(stats.by_code[:invalid_input]).to eq(1)
      end

      it "limits recent_errors to 100" do
        101.times do |i|
          stats.record(Fractor::WorkResult.new(
                         error: StandardError.new("Error #{i}"),
                       ))
        end

        expect(stats.recent_errors.size).to eq(100)
      end
    end

    describe "#error_rate" do
      it "calculates errors per second" do
        stats.record(Fractor::WorkResult.new(
                       error: StandardError.new("Error"),
                     ))
        sleep 0.1
        stats.record(Fractor::WorkResult.new(
                       error: StandardError.new("Error"),
                     ))

        expect(stats.error_rate).to be > 0
      end
    end

    describe "#most_common_code" do
      it "returns most frequent error code" do
        3.times do
          stats.record(Fractor::WorkResult.new(
                         error: StandardError.new("Error"),
                         error_code: :timeout,
                       ))
        end
        stats.record(Fractor::WorkResult.new(
                       error: StandardError.new("Error"),
                       error_code: :invalid,
                     ))

        expect(stats.most_common_code).to eq(:timeout)
      end
    end

    describe "#highest_severity" do
      it "returns most severe error level" do
        stats.record(Fractor::WorkResult.new(
                       error: StandardError.new("Error"),
                       error_severity: :warning,
                     ))
        stats.record(Fractor::WorkResult.new(
                       error: StandardError.new("Error"),
                       error_severity: :critical,
                     ))

        expect(stats.highest_severity).to eq(:critical)
      end
    end

    describe "#increasing?" do
      it "detects increasing error rates" do
        15.times do
          stats.record(Fractor::WorkResult.new(
                         error: StandardError.new("Error"),
                       ))
        end

        expect(stats.increasing?).to be true
      end

      it "returns false with insufficient data" do
        5.times do
          stats.record(Fractor::WorkResult.new(
                         error: StandardError.new("Error"),
                       ))
        end

        expect(stats.increasing?).to be false
      end
    end

    describe "#to_h" do
      before do
        stats.record(Fractor::WorkResult.new(
                       error: StandardError.new("Error"),
                       error_severity: :error,
                       error_code: :test,
                     ))
      end

      it "returns summary hash" do
        hash = stats.to_h
        expect(hash).to include(
          :category,
          :total_count,
          :error_rate,
          :by_severity,
          :by_code,
          :most_common_code,
          :highest_severity,
          :trending,
        )
      end
    end
  end
end
