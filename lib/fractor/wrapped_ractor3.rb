# frozen_string_literal: true

require "timeout"
require_relative "wrapped_ractor"
require_relative "logger"

module Fractor
  # Ruby 3.x specific implementation of WrappedRactor.
  # Uses Ractor.yield for sending messages back from workers.
  class WrappedRactor3 < WrappedRactor
    # Initializes the WrappedRactor3.
    # The response_port parameter is accepted for API compatibility but not used in Ruby 3.x.
    #
    # @param name [String] Name for the ractor
    # @param worker_class [Class] Worker class to instantiate
    # @param response_port [Object, nil] Unused in Ruby 3.x (for API compatibility with Ruby 4.0)
    def initialize(name, worker_class, response_port: nil)
      super(name, worker_class)
      # response_port is not used in Ruby 3.x
    end

    # Starts the underlying Ractor using Ractor.yield pattern.
    def start
      RactorLogger.info("Starting Ractor #{@name} (Ruby 3.x mode)",
                        ractor_name: @name)

      # Capture timeout value before entering ractor (Ractors can't access Fractor.config)
      # Get class-level timeout, or fall back to default of nil (no timeout)
      # Note: We avoid accessing Fractor.config from ractor creation context
      class_level_timeout = @worker_class.worker_timeout

      # Pass worker_class and timeout to the Ractor block
      @ractor = Ractor.new(@name, @worker_class,
                           class_level_timeout) do |name, worker_cls, timeout_val|
        RactorLogger.debug(
          "Ractor started with worker class #{worker_cls} and timeout #{timeout_val.inspect}", ractor_name: name
        )
        # Yield an initialization message
        Ractor.yield({ type: :initialize, processor: name })

        # Instantiate the specific worker inside the Ractor
        # Pass timeout as an option only if it's not nil, to avoid accessing self.class from ractor
        worker = if timeout_val.nil?
                   worker_cls.new(name: name)
                 else
                   worker_cls.new(name: name, timeout: timeout_val)
                 end

        loop do
          # Ractor.receive will block until a message is received
          RactorLogger.debug("Waiting for work", ractor_name: name)
          work = Ractor.receive

          # Handle shutdown message
          if work == :shutdown
            RactorLogger.debug("Received shutdown message, terminating",
                               ractor_name: name)
            # Yield a shutdown acknowledgment before terminating
            Ractor.yield({ type: :shutdown, processor: name })
            break
          end

          RactorLogger.debug("Received work #{work.inspect}", ractor_name: name)

          begin
            # Get the timeout for this specific work item
            # Priority: work.timeout > worker.timeout (nil means no timeout)
            work_timeout = if work.respond_to?(:timeout) && !work.timeout.nil?
                             work.timeout
                           else
                             worker.timeout
                           end

            # Process the work with timeout if configured
            # Note: Ruby's Timeout.timeout uses threads which don't work with Ractors.
            # We measure execution time and raise timeout error afterward if exceeded.
            result = if work_timeout
                       start_time = Time.now
                       process_result = worker.process(work)
                       elapsed = Time.now - start_time
                       if elapsed > work_timeout
                         # Raise a timeout error after the fact
                         # Note: This is a post-facto timeout check - the work has already completed
                         raise Timeout::Error,
                               "execution timed out after #{elapsed}s (limit: #{work_timeout}s)"
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
            # Yield the result back
            Ractor.yield({ type: :result, result: work_result,
                           processor: name })
          rescue Timeout::Error => e
            # Handle timeout errors as retriable errors
            RactorLogger.warn(
              "Timed out after #{work_timeout}s processing work #{work.inspect}", ractor_name: name
            )
            error_result = Fractor::WorkResult.new(
              error: "Worker timeout: #{e.message}",
              work: work,
              error_category: :timeout,
            )
            Ractor.yield({ type: :error, result: error_result,
                           processor: name })
          rescue StandardError => e
            # Handle errors during processing
            RactorLogger.error("Error processing work #{work.inspect}",
                               ractor_name: name, exception: e)
            # Yield an error message back
            # Ensure the original work object is included in the error result
            error_result = Fractor::WorkResult.new(error: e.message, work: work)
            Ractor.yield({ type: :error, result: error_result,
                           processor: name })
          end
        end
      rescue Ractor::ClosedError
        RactorLogger.debug("Ractor closed", ractor_name: @name)
      rescue StandardError => e
        RactorLogger.error("Unexpected error", ractor_name: @name, exception: e)
      ensure
        RactorLogger.debug("Ractor shutting down", ractor_name: @name)
      end
      RactorLogger.debug("Ractor instance created: #{@ractor}",
                         ractor_name: @name)
    end

    # Sends work to the Ractor.
    #
    # @param work [Fractor::Work] The work item to process
    # @return [Boolean] true if sent successfully, false otherwise
    def send(work)
      if @ractor
        begin
          @ractor.send(work)
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

    # Receives a message from the Ractor using Ractor.take.
    #
    # @return [Hash, nil] The message received or nil
    def receive_message
      @ractor&.take
    end
  end
end
