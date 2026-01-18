# frozen_string_literal: true

module Fractor
  # Represents the result of processing a Work item.
  # Can hold either a successful result or an error with rich metadata.
  class WorkResult
    # Error severity levels
    SEVERITY_CRITICAL = :critical  # System-breaking errors
    SEVERITY_ERROR = :error        # Standard errors
    SEVERITY_WARNING = :warning    # Non-fatal issues
    SEVERITY_INFO = :info          # Informational

    # Error categories
    CATEGORY_VALIDATION = :validation # Input validation errors
    CATEGORY_TIMEOUT = :timeout          # Timeout errors
    CATEGORY_NETWORK = :network          # Network-related errors
    CATEGORY_RESOURCE = :resource        # Resource exhaustion
    CATEGORY_BUSINESS = :business        # Business logic errors
    CATEGORY_SYSTEM = :system            # System errors
    CATEGORY_UNKNOWN = :unknown          # Unknown/uncategorized

    attr_reader :result, :error, :work, :error_code, :error_context,
                :error_category, :error_severity, :suggestion, :stack_trace

    def initialize(
      result: nil,
      error: nil,
      work: nil,
      error_code: nil,
      error_context: nil,
      error_category: nil,
      error_severity: nil,
      suggestion: nil,
      stack_trace: nil
    )
      @result = result
      @error = error
      @work = work
      @error_code = error_code
      @error_context = error_context || {}
      @error_category = error_category || infer_category(error)
      @error_severity = error_severity || infer_severity(error)
      @suggestion = suggestion || infer_suggestion(error)
      @stack_trace = stack_trace || capture_stack_trace(error)
    end

    def success?
      !@error
    end

    def failure?
      !success?
    end

    # Check if error is critical
    def critical?
      @error_severity == SEVERITY_CRITICAL
    end

    # Check if error is retriable based on category
    def retriable?
      return false if success?

      retriable_categories = [
        CATEGORY_TIMEOUT,
        CATEGORY_NETWORK,
        CATEGORY_RESOURCE,
      ]
      retriable_categories.include?(@error_category)
    end

    # Get full error information as hash
    def error_info
      return nil if success?

      {
        error: @error,
        error_class: @error&.class&.name,
        error_message: @error&.message,
        error_code: @error_code,
        error_category: @error_category,
        error_severity: @error_severity,
        error_context: @error_context,
        suggestion: @suggestion,
        stack_trace: @stack_trace,
      }
    end

    def to_s
      if success?
        "Result: #{@result}"
      else
        "Error: #{@error}, Code: #{@error_code}, Category: #{@error_category}, Severity: #{@error_severity}"
      end
    end

    def inspect
      if success?
        {
          result: @result,
          work: @work&.to_s,
        }
      else
        {
          error: @error,
          error_code: @error_code,
          error_category: @error_category,
          error_severity: @error_severity,
          error_context: @error_context,
          work: @work&.to_s,
        }
      end
    end

    private

    # Infer error category from error type
    def infer_category(error)
      return nil unless error

      case error
      when ArgumentError, TypeError
        CATEGORY_VALIDATION
      when Timeout::Error
        CATEGORY_TIMEOUT
      when defined?(SocketError) ? SocketError : nil, Errno::ECONNREFUSED, Errno::ETIMEDOUT
        CATEGORY_NETWORK
      when Errno::ENOMEM, Errno::ENOSPC
        CATEGORY_RESOURCE
      when SystemCallError, SystemStackError
        CATEGORY_SYSTEM
      else
        CATEGORY_UNKNOWN
      end
    end

    # Infer error severity from error type
    def infer_severity(error)
      return nil unless error

      case error
      when SystemStackError, Errno::ENOMEM
        SEVERITY_CRITICAL
      when StandardError
        SEVERITY_ERROR
      else
        SEVERITY_WARNING
      end
    end

    # Infer suggestion from error type
    def infer_suggestion(error)
      return nil unless error

      error_msg = error.to_s.downcase

      case error_msg
      when /negative number/i, /must be positive/i
        "Ensure input values are positive. Consider using absolute value or validating input range."
      when /timeout/i
        "Consider increasing timeout duration or breaking work into smaller chunks."
      when /memory/i, /out of memory/i
        "Try processing smaller batches or increasing available memory."
      when /connection/i, /network/i, /refused/i
        "Verify network connectivity and service availability. Check firewall settings."
      when /undefined method/i, /no method/i
        "Ensure the Worker class implements all required methods for the Work type."
      when /nil/i, /null/i
        "Check if work items are being initialized with valid input data."
      when /argument/i, /type/i
        "Verify input data types match expected format. Check Work item initialization."
      when /file/i, /not found/i
        "Ensure file paths are correct and files exist before processing."
      when /permission/i, /authorized/i
        "Check file permissions and ensure proper access rights for the operation."
      else
        "Check the error message and ensure all requirements are met. Enable debug logging for more details."
      end
    end

    # Capture stack trace from error if available
    def capture_stack_trace(error)
      return nil unless error

      # If error is a string, return nil
      return nil unless error.is_a?(Exception)

      # Get backtrace from exception
      error.backtrace
    rescue StandardError
      nil
    end
  end
end
