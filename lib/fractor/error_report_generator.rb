# frozen_string_literal: true

require "json"

module Fractor
  # Generates error reports in multiple formats (text, JSON, Prometheus).
  # Extracted from ErrorReporter for better separation of concerns.
  class ErrorReportGenerator
    # Generate a human-readable text report
    #
    # @param report_data [Hash] The report data from ErrorReporter
    # @return [String] Formatted text report
    def self.text_report(report_data)
      lines = []
      lines << "=" * 80
      lines << "ERROR REPORT"
      lines << "=" * 80
      lines << ""

      # Summary
      lines << "SUMMARY"
      lines << "-" * 80
      summary = report_data[:summary]
      lines << "Uptime:          #{summary[:uptime]}s"
      lines << "Total Errors:    #{summary[:total_errors]}"
      lines << "Total Successes: #{summary[:total_successes]}"
      lines << "Error Rate:      #{summary[:error_rate]}%"
      lines << ""

      # Errors by Severity
      lines << "Errors by Severity:"
      summary[:errors_by_severity].each do |severity, count|
        lines << "  #{severity.to_s.ljust(10)}: #{count}"
      end
      lines << ""

      # Top Categories
      lines << "TOP ERROR CATEGORIES"
      lines << "-" * 80
      report_data[:top_categories].each do |category, count|
        lines << "#{category.to_s.ljust(20)}: #{count} errors"
      end
      lines << ""

      # Top Jobs
      unless report_data[:top_jobs].empty?
        lines << "TOP ERROR JOBS"
        lines << "-" * 80
        report_data[:top_jobs].each do |job, count|
          lines << "#{job.to_s.ljust(20)}: #{count} errors"
        end
        lines << ""
      end

      # Critical Errors
      unless report_data[:critical_errors].empty?
        lines << "CRITICAL ERRORS"
        lines << "-" * 80
        report_data[:critical_errors].each do |error_info|
          lines << "Category: #{error_info[:category]}"
          lines << "Count:    #{error_info[:count]}"
          lines << "Recent errors:"
          error_info[:recent].each do |err|
            lines << "  - [#{err[:timestamp]}] #{err[:error_class]}: #{err[:error_message]}"
          end
          lines << ""
        end
      end

      # Trending Errors
      unless report_data[:trending_errors].empty?
        lines << "TRENDING ERRORS (Increasing)"
        lines << "-" * 80
        report_data[:trending_errors].each do |trend|
          stats = trend[:stats]
          lines << "Category:    #{stats[:category]}"
          lines << "Total Count: #{stats[:total_count]}"
          lines << "Error Rate:  #{stats[:error_rate]}/s"
          lines << "Trend:       #{stats[:trending]}"
          lines << ""
        end
      end

      lines << "=" * 80
      lines.join("\n")
    end

    # Export errors to Prometheus format
    #
    # @param reporter [ErrorReporter] The error reporter instance
    # @return [String] Prometheus metrics
    def self.to_prometheus(reporter)
      lines = []

      # Total errors
      lines << "# HELP fractor_errors_total Total number of errors"
      lines << "# TYPE fractor_errors_total counter"
      lines << "fractor_errors_total #{reporter.total_errors}"
      lines << ""

      # Total successes
      lines << "# HELP fractor_successes_total Total number of successes"
      lines << "# TYPE fractor_successes_total counter"
      lines << "fractor_successes_total #{reporter.total_successes}"
      lines << ""

      # Error rate
      lines << "# HELP fractor_error_rate Error rate percentage"
      lines << "# TYPE fractor_error_rate gauge"
      lines << "fractor_error_rate #{reporter.overall_error_rate}"
      lines << ""

      # Errors by severity
      lines << "# HELP fractor_errors_by_severity Errors by severity level"
      lines << "# TYPE fractor_errors_by_severity gauge"
      reporter.errors_by_severity.each do |severity, count|
        lines << "fractor_errors_by_severity{severity=\"#{severity}\"} #{count}"
      end
      lines << ""

      # Errors by category
      lines << "# HELP fractor_errors_by_category Errors by category"
      lines << "# TYPE fractor_errors_by_category gauge"
      reporter.instance_variable_get(:@by_category)&.each do |category, stats|
        lines << "fractor_errors_by_category{category=\"#{category}\"} #{stats.total_count}"
      end
      lines << ""

      # Errors by job
      by_job = reporter.instance_variable_get(:@by_job)
      unless by_job&.empty?
        lines << "# HELP fractor_errors_by_job Errors by job name"
        lines << "# TYPE fractor_errors_by_job gauge"
        by_job.each do |job, stats|
          lines << "fractor_errors_by_job{job=\"#{job}\"} #{stats.total_count}"
        end
        lines << ""
      end

      lines.join("\n")
    end

    # Export errors to JSON format
    #
    # @param report_data [Hash] The report data from ErrorReporter
    # @param args [Array] Additional arguments for JSON generation
    # @return [String] JSON representation
    def self.to_json(report_data, *args)
      report_data.to_json(*args)
    end
  end
end
