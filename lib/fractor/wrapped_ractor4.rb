# frozen_string_literal: true

require "timeout"
require_relative "wrapped_ractor"
require_relative "logger"

module Fractor
  # Ruby 4.0+ specific implementation of WrappedRactor.
  # Uses Ractor::Port for communication - main ractor creates response ports
  # and passes them to workers when sending work.
  class WrappedRactor4 < WrappedRactor
    attr_reader :response_port

    # Initializes the WrappedRactor with a name, worker class, and response port.
    #
    # @param name [String] Name for the ractor
    # @param worker_class [Class] Worker class to instantiate
    # @param response_port [Ractor::Port, nil] The port to receive responses on (created by main ractor)
    def initialize(name, worker_class, response_port: nil)
      super(name, worker_class)
      @response_port = response_port
    end

    # Sets the response port for this worker.
    #
    # @param port [Ractor::Port] The port to receive responses on
    def response_port=(port)
      @response_port = port
    end

    # Starts the underlying Ractor using the port-based pattern.
    # In Ruby 4.0:
    # - Main ractor creates response ports (one per worker)
    # - Main ractor sends [work, response_port] to workers
    # - Workers receive work and response_port, send results back via response_port
    def start
      RactorLogger.info("Starting Ractor #{@name} (Ruby 4.0 mode)",
                        ractor_name: @name)

      # Capture timeout value before entering ractor (Ractors can't access Fractor.config)
      # Get class-level timeout, or fall back to default of nil (no timeout)
      # Note: We avoid accessing Fractor.config from ractor creation context
      class_level_timeout = @worker_class.worker_timeout

      # In Ruby 4.0, workers don't create their own ports
      # They receive response_port from main ractor when work is sent
      @ractor = Ractor.new(@name, @worker_class,
                           class_level_timeout) do |name, worker_cls, timeout_val|
        RactorLogger.debug(
          "Ractor started with worker class #{worker_cls} and timeout #{timeout_val.inspect}", ractor_name: name
        )

        # Instantiate the specific worker inside the Ractor
        # Pass timeout as an option only if it's not nil, to avoid accessing self.class from ractor
        worker = if timeout_val.nil?
                   worker_cls.new(name: name)
                 else
                   worker_cls.new(name: name, timeout: timeout_val)
                 end

        # Main message processing loop
        loop do
          # Receive work from the main ractor (blocks until message available)
          # In Ruby 4.0, main sends [work, response_port]
          received = Ractor.receive
          RactorLogger.debug("Received #{received.inspect}", ractor_name: name)

          # Handle shutdown message
          if received == :shutdown
            RactorLogger.debug("Received shutdown message, terminating",
                               ractor_name: name)
            break
          end

          # Extract work and response_port
          # Main should send [work, response_port]
          if received.is_a?(Array) && received.size == 2
            work, response_port = received
          else
            # Legacy format for initialization or other messages
            work = received
            response_port = nil
          end

          # Handle initialize message (for backwards compatibility during startup)
          if work.is_a?(Hash) && work[:type] == :initialize
            RactorLogger.debug("Worker initialized", ractor_name: name)
            next
          end

          begin
            # Get the timeout for this worker (nil means no timeout)
            worker_timeout = worker.timeout

            # Process the work with timeout if configured
            # Note: Ruby's Timeout.timeout uses threads which don't work with Ractors.
            # We measure execution time and raise timeout error afterward if exceeded.
            result = if worker_timeout
                       start_time = Time.now
                       process_result = worker.process(work)
                       elapsed = Time.now - start_time
                       if elapsed > worker_timeout
                         # Raise a timeout error after the fact
                         # Note: This is a post-facto timeout check - the work has already completed
                         raise Timeout::Error,
                               "execution timed out after #{elapsed}s (limit: #{worker_timeout}s)"
                       end

                       process_result
                     else
                       worker.process(work)
                     end

            RactorLogger.debug("Sending result #{result.inspect}",
                               ractor_name: name)

            # Wrap the result in a WorkResult object if not already wrapped
            work_result = if result.is_a?(Fractor::WorkResult)
                            result
                          else
                            Fractor::WorkResult.new(result: result, work: work)
                          end

            # Send the result back through the response port
            if response_port
              response_port << { type: :result, result: work_result,
                                 processor: name }
            else
              RactorLogger.warn("No response port available, result lost",
                                ractor_name: name)
            end
          rescue Timeout::Error => e
            # Handle timeout errors as retriable errors
            RactorLogger.warn(
              "Timed out after #{worker.timeout}s processing work #{work.inspect}", ractor_name: name
            )
            error_result = Fractor::WorkResult.new(
              error: "Worker timeout: #{e.message}",
              work: work,
              error_category: :timeout,
            )
            if response_port
              response_port << { type: :error, result: error_result,
                                 processor: name }
            end
          rescue StandardError => e
            # Handle errors during processing
            RactorLogger.error("Error processing work #{work.inspect}",
                               ractor_name: name, exception: e)

            # Send an error message back through the response port
            # Ensure the original work object is included in the error result
            error_result = Fractor::WorkResult.new(error: e.message, work: work)
            if response_port
              response_port << { type: :error, result: error_result,
                                 processor: name }
            end
          end
        end
      rescue Ractor::ClosedError
        RactorLogger.debug("Ractor closed", ractor_name: name)
      rescue StandardError => e
        RactorLogger.error("Unexpected error", ractor_name: name, exception: e)
      ensure
        RactorLogger.debug("Ractor shutting down", ractor_name: name)
      end
      RactorLogger.debug("Ractor instance created", ractor_name: name)
    end
    RactorLogger.debug("Ractor #{@ractor} started", ractor_name: @name)

    # Sends work to the Ractor.
    # In Ruby 4.0, sends [work, response_port] so worker can reply back.
    # Special case: sends just :shutdown for shutdown messages.
    #
    # @param work [Fractor::Work, Symbol] The work item to process, or :shutdown
    # @return [Boolean] true if sent successfully, false otherwise
    def send(work)
      if @ractor
        begin
          # In Ruby 4.0, send [work, response_port] so worker can reply
          # Special case: shutdown is sent as a symbol, not an array
          if work == :shutdown
            @ractor.send(:shutdown)
          else
            @ractor.send([work, @response_port])
          end
          true
        rescue Exception => e
          RactorLogger.warn("Error sending work to Ractor: #{e.message}",
                            ractor_name: @name)
          false
        end
      else
        RactorLogger.warn("Attempted to send work to nil Ractor",
                          ractor_name: @name)
        false
      end
    end

    # Receives a message from the Ractor.
    # In Ruby 4.0, messages come through response ports in the main loop.
    # This method is kept for backwards compatibility with tests.
    #
    # Note: In Ruby 4.0, this will block if no message is available.
    # The test should either skip this or ensure a message was sent first.
    #
    # @return [Hash, nil] The message received or nil
    def receive_message
      # In Ruby 4.0, we receive through the response_port
      # Try to receive with a small timeout to avoid blocking indefinitely
      return nil unless @response_port

      # Use a non-blocking receive attempt
      # In Ruby 4.0, if the port is empty, this would block
      # For test compatibility, we return nil if no message is available
      @response_port.receive
    rescue Ractor::ClosedError, Ractor::Error
      nil
    end

    # Closes the Ractor and its response port.
    # In Ruby 4.0, we need to explicitly close the response port
    # to prevent Ractor.select from hanging.
    #
    # @return [Boolean] true if closed successfully
    def close
      # Close the response port first
      if @response_port
        begin
          # Send nil through the port to signal it's closing
          @response_port.send(nil) if @response_port.respond_to?(:send)
        rescue StandardError
          # Port may already be closed
        end
        @response_port = nil
      end

      # Then close the underlying ractor
      super
    end
  end
end
