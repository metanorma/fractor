# frozen_string_literal: true

require_relative "error_statistics"
require_relative "error_report_generator"

module Fractor
  # Error reporting and analytics system.
  # Aggregates errors, tracks statistics, and provides actionable insights.
  class ErrorReporter
    attr_reader :start_time, :total_errors, :total_successes

    def initialize
      @start_time = Time.now
      @total_errors = 0
      @total_successes = 0
      @by_category = {}
      @by_job = {}
      @error_handlers = []
      @mutex = Mutex.new
    end

    # Record a work result
    #
    # @param work_result [WorkResult] The work result to record
    # @param job_name [String, nil] Optional job name
    # @return [void]
    def record(work_result, job_name: nil)
      @mutex.synchronize do
        if work_result.success?
          @total_successes += 1
        else
          @total_errors += 1
          record_error(work_result, job_name)
        end
      end
    end

    # Register an error handler callback
    #
    # @yield [work_result, job_name] Block to call when error occurs
    # @return [void]
    def on_error(&block)
      @error_handlers << block
    end

    # Get statistics for a category
    #
    # @param category [String, Symbol] The error category
    # @return [Hash, nil] Statistics for the category
    def category_stats(category)
      @mutex.synchronize do
        @by_category[category]&.to_h
      end
    end

    # Get statistics for a job
    #
    # @param job_name [String] The job name
    # @return [Hash, nil] Statistics for the job
    def job_stats(job_name)
      @mutex.synchronize do
        @by_job[job_name]&.to_h
      end
    end

    # Get overall error rate
    #
    # @return [Float] Error rate percentage
    def overall_error_rate
      total = @total_errors + @total_successes
      return 0.0 if total.zero?

      (@total_errors.to_f / total * 100).round(2)
    end

    # Get errors by severity
    #
    # @return [Hash] Error counts grouped by severity
    def errors_by_severity
      result = Hash.new(0)
      @mutex.synchronize do
        @by_category.each_value do |stats|
          stats.by_severity.each do |severity, count|
            result[severity] += count
          end
        end
      end
      result
    end

    # Get top error categories
    #
    # @param limit [Integer] Maximum number of categories to return
    # @return [Hash] Top error categories with counts
    def top_categories(limit: 5)
      @mutex.synchronize do
        @by_category
          .map { |category, stats| [category, stats.total_count] }
          .sort_by { |_category, count| -count }
          .first(limit)
          .to_h
      end
    end

    # Get top error jobs
    #
    # @param limit [Integer] Maximum number of jobs to return
    # @return [Hash] Top error jobs with counts
    def top_jobs(limit: 5)
      @mutex.synchronize do
        @by_job
          .map { |job, stats| [job, stats.total_count] }
          .sort_by { |_job, count| -count }
          .first(limit)
          .to_h
      end
    end

    # Get critical errors
    #
    # @return [Array<Hash>] Critical errors with recent occurrences
    def critical_errors
      errors = []
      @mutex.synchronize do
        @by_category.each do |category, stats|
          critical_count = stats.by_severity[WorkResult::SEVERITY_CRITICAL] || 0
          if critical_count.positive?
            errors << {
              category: category,
              count: critical_count,
              recent: stats.recent_errors.select do |e|
                e[:error_severity] == WorkResult::SEVERITY_CRITICAL
              end.last(5),
            }
          end
        end
      end
      errors
    end

    # Get trending errors (increasing error rates)
    #
    # @return [Array<Hash>] Trending error categories
    def trending_errors
      trends = []
      @mutex.synchronize do
        @by_category.each do |category, stats|
          if stats.increasing?
            trends << { category: category,
                        stats: stats.to_h }
          end
        end
      end
      trends
    end

    # Generate comprehensive report
    #
    # @return [Hash] Report data with all statistics
    def report
      {
        summary: {
          uptime: (Time.now - @start_time).round(2),
          total_errors: @total_errors,
          total_successes: @total_successes,
          error_rate: overall_error_rate,
          errors_by_severity: errors_by_severity,
        },
        top_categories: top_categories,
        top_jobs: top_jobs,
        critical_errors: critical_errors,
        trending_errors: trending_errors,
        category_breakdown: category_breakdown,
      }
    end

    # Generate formatted text report
    #
    # @return [String] Formatted text report
    def formatted_report
      ErrorReportGenerator.text_report(report)
    end

    # Export to Prometheus format
    #
    # @return [String] Prometheus metrics
    def to_prometheus
      ErrorReportGenerator.to_prometheus(self)
    end

    # Export to JSON format
    #
    # @param args [Array] Additional arguments for JSON generation
    # @return [String] JSON representation
    def to_json(*args)
      ErrorReportGenerator.to_json(report, *args)
    end

    # Reset all statistics
    #
    # @return [void]
    def reset
      @mutex.synchronize do
        @start_time = Time.now
        @total_errors = 0
        @total_successes = 0
        @by_category.clear
        @by_job.clear
      end
    end

    private

    def record_error(work_result, job_name)
      # Record by category
      category = work_result.error_category
      @by_category[category] ||= ErrorStatistics.new(category)
      @by_category[category].record(work_result)

      # Record by job if provided
      if job_name
        @by_job[job_name] ||= ErrorStatistics.new(job_name)
        @by_job[job_name].record(work_result)
      end

      # Invoke error handlers
      @error_handlers.each do |handler|
        handler.call(work_result, job_name)
      rescue StandardError => e
        warn "Error in error handler: #{e.message}"
      end
    end

    def category_breakdown
      breakdown = {}
      @mutex.synchronize do
        @by_category.each do |category, stats|
          breakdown[category] = stats.to_h
        end
      end
      breakdown
    end
  end
end
