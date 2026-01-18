# frozen_string_literal: true

module Fractor
  # Formats error messages with rich context for debugging.
  # Extracted from Supervisor to follow Single Responsibility Principle.
  #
  # @example Basic usage
  #   formatter = ErrorFormatter.new
  #   error_message = formatter.format(wrapped_ractor, error_result)
  class ErrorFormatter
    # Format error context with rich information for debugging.
    #
    # @param wrapped_ractor [WrappedRactor] The worker that encountered the error
    # @param error_result [WorkResult] The error result
    # @return [String] Formatted error message with context
    def format(wrapped_ractor, error_result)
      timestamp = Time.now.strftime("%Y-%m-%d %H:%M:%S")
      worker_class = wrapped_ractor.worker_class
      worker_name = wrapped_ractor.name

      # Build contextual error message
      lines = [
        "=" * 80,
        "[#{timestamp}] ERROR PROCESSING WORK",
        "=" * 80,
        "Worker: #{worker_name} (#{worker_class})",
        "Work Item: #{error_result.work&.inspect || 'unknown'}",
        "Error: #{error_result.error}",
      ]

      # Add error category and severity if available
      if error_result.respond_to?(:error_category) && error_result.error_category
        lines << "Category: #{error_result.error_category}"
      end
      if error_result.respond_to?(:error_severity) && error_result.error_severity
        lines << "Severity: #{error_result.error_severity}"
      end

      # Add suggestions based on error type
      suggestion = suggest_fix_for(error_result)
      lines << "Suggestion: #{suggestion}" if suggestion

      lines << "=" * 80
      lines.join("\n")
    end

    private

    # Provide contextual suggestions for common errors.
    #
    # @param error_result [WorkResult] The error result
    # @return [String, nil] Suggestion string or nil
    def suggest_fix_for(error_result)
      error_msg = error_result.error.to_s

      case error_msg
      when /negative number/i
        "Check if input validation is needed. Consider using AbsWorker for positive-only values."
      when /timeout/i
        "Consider increasing timeout duration or breaking work into smaller chunks."
      when /memory/i
        "Try processing smaller batches or increasing available memory."
      when /connection/i
        "Verify network connectivity and service availability."
      when /undefined method/i
        "Ensure the Worker class implements all required methods for the Work type."
      when /nil/i
        "Check if work items are being initialized with valid input data."
      end
    end
  end
end
