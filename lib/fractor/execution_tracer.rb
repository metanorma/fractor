# frozen_string_literal: true

module Fractor
  # Traces work item flow through the Fractor system for debugging.
  # When enabled via FRACTOR_TRACE=1, captures the complete lifecycle of each work item.
  #
  # @example Instance-based usage (recommended)
  #   tracer = ExecutionTracer.new(enabled: true)
  #   tracer.trace(:created, work, worker_name: "MyWorker")
  #
  # @example Class-based usage (for backward compatibility)
  #   ExecutionTracer.enabled = true
  #   ExecutionTracer.trace(:created, work, worker_name: "MyWorker")
  class ExecutionTracer
    attr_reader :enabled, :trace_stream

    # Initialize a new execution tracer instance.
    #
    # @param enabled [Boolean] Whether tracing is enabled
    # @param trace_stream [IO] Output stream for trace messages
    # @param check_env [Boolean] Whether to check FRACTOR_TRACE env var
    def initialize(enabled: nil, trace_stream: nil, check_env: true)
      @enabled = enabled || (check_env && ENV["FRACTOR_TRACE"] == "1")
      @trace_stream = trace_stream || $stderr
      @check_env = check_env
    end

    # Trace an event in the work item lifecycle.
    #
    # @param event [Symbol] The event type (:created, :queued, :assigned, :processing, :completed, :failed)
    # @param work [Work] The work item
    # @param context [Hash] Additional context (worker_name, timestamp, etc.)
    def trace(event, work = nil, context = {})
      return unless enabled?

      timestamp = Time.now.strftime("%Y-%m-%d %H:%M:%S.%3N")
      thread_id = Thread.current.object_id

      # Build trace line
      trace_line = build_trace_line(timestamp, event, work, context, thread_id)

      # Output to trace stream
      trace_stream.puts(trace_line)
    end

    # Set a custom trace stream.
    #
    # @param io [IO] The output stream
    def trace_stream=(io)
      @trace_stream = io
    end

    # Enable tracing.
    def enable!
      @enabled = true
    end

    # Disable tracing.
    def disable!
      @enabled = false
    end

    # Check if tracing is enabled.
    #
    # @return [Boolean] true if tracing is enabled
    def enabled?
      @enabled || (@check_env && ENV["FRACTOR_TRACE"] == "1")
    end

    # Reset tracer state.
    def reset!
      @enabled = nil
      @trace_stream = $stderr
    end

    # Class-level convenience methods for backward compatibility.
    # These use a singleton instance for global tracing.
    class << self
      # Enable or disable tracing (global).
      #
      # @param value [Boolean] Whether to enable tracing
      def enabled=(value)
        instance.enabled = value
      end

      # Check if global tracing is enabled.
      #
      # @return [Boolean] true if tracing is enabled
      def enabled?
        instance.enabled?
      end

      # Trace an event using the global tracer instance.
      #
      # @param event [Symbol] The event type
      # @param work [Work] The work item
      # @param context [Hash] Additional context
      def trace(event, work = nil, context = {})
        instance.trace(event, work, context)
      end

      # Get the global trace stream.
      #
      # @return [IO] The output stream
      def trace_stream
        instance.trace_stream
      end

      # Set a custom global trace stream.
      #
      # @param io [IO] The output stream
      def trace_stream=(io)
        instance.trace_stream = io
      end

      # Reset all global state (useful for testing and isolation).
      def reset!
        instance.reset!
      end

      # Get the singleton tracer instance.
      #
      # @return [ExecutionTracer] The global instance
      def instance
        @instance ||= new
      end
    end

    private

    # Build a formatted trace line.
    #
    # @param timestamp [String] Formatted timestamp
    # @param event [Symbol] The event type
    # @param work [Work] The work item
    # @param context [Hash] Additional context
    # @param thread_id [Integer] Thread ID
    # @return [String] Formatted trace line
    def build_trace_line(timestamp, event, work, context, thread_id)
      parts = [
        "[TRACE]",
        timestamp,
        "[T#{thread_id}]",
        event.to_s.upcase,
      ]

      # Add work item info if available
      if work
        work_info = work.instance_of?(::Fractor::Work) ? "Work" : work.class.name
        parts << "#{work_info}:#{work.object_id}"
      end

      # Add context info
      parts << "worker=#{context[:worker_name]}" if context[:worker_name]
      parts << "class=#{context[:worker_class]}" if context[:worker_class]
      parts << "duration=#{context[:duration_ms]}ms" if context[:duration_ms]
      parts << "queue_size=#{context[:queue_size]}" if context[:queue_size]

      parts.join(" ")
    end
  end
end
