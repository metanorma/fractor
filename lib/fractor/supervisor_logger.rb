# frozen_string_literal: true

module Fractor
  # Handles logging for Supervisor operations.
  # Extracted from Supervisor to follow Single Responsibility Principle.
  class SupervisorLogger
    attr_reader :logger, :debug_enabled

    def initialize(logger: :default, debug: false)
      @logger = if logger == :default
                  Fractor.logger
                else
                  logger
                end
      @debug_enabled = debug
    end

    # Log debug message (only when debug mode is enabled)
    def debug(message)
      return unless @debug_enabled

      if @logger
        @logger.debug("[Fractor] #{message}")
      else
        puts "[DEBUG] #{message}"
      end
    end

    # Log info message
    def info(message)
      if @logger
        @logger.info("[Fractor] #{message}")
      else
        puts "[INFO] #{message}"
      end
    end

    # Log warning message
    def warn(message)
      if @logger
        @logger.warn("[Fractor] #{message}")
      else
        warn "[WARN] #{message}"
      end
    end

    # Log error message
    def error(message)
      if @logger
        @logger.error("[Fractor] #{message}")
      else
        $stderr.puts "[ERROR] #{message}"
      end
    end

    # Log work item status
    def log_work_added(work, total_count, queue_size)
      debug "Work item added: #{work.inspect}"
      debug "Initial work count: #{total_count}, Queue size: #{queue_size}"
    end

    # Log worker status
    def log_worker_status(total:, idle:, busy:)
      debug "Workers: #{total} total, #{idle} idle, #{busy} busy"
    end

    # Log processing status
    def log_processing_status(processed:, total:, queue_size:)
      debug "Processing: #{processed}/#{total}, Queue size: #{queue_size}"
    end

    # Log result received
    def log_result_received(result)
      debug "Result received: #{result.inspect}"
    end

    # Log error received
    def log_error_received(error_result)
      error "Error in worker: #{error_result.error}"
      error "Work item: #{error_result.work.inspect}"
    end

    # Enable or disable debug mode
    def debug=(enabled)
      @debug_enabled = enabled
    end
  end
end
