# frozen_string_literal: true

module Fractor
  # Wraps a Ruby Ractor to manage a worker instance.
  # Handles communication and error propagation.
  class WrappedRactor
    attr_reader :ractor, :name, :worker_class

    # Initializes the WrappedRactor with a name and the Worker class to instantiate.
    # The worker_class parameter allows flexibility in specifying the worker type.
    def initialize(name, worker_class)
      puts "Creating Ractor #{name} with worker #{worker_class}" if ENV["FRACTOR_DEBUG"]
      @name = name
      @worker_class = worker_class # Store the worker class
      @ractor = nil # Initialize ractor as nil
    end

    # Starts the underlying Ractor.
    def start
      puts "Starting Ractor #{@name}" if ENV["FRACTOR_DEBUG"]
      # Pass worker_class to the Ractor block
      @ractor = Ractor.new(@name, @worker_class) do |name, worker_cls|
        puts "Ractor #{name} started with worker class #{worker_cls}" if ENV["FRACTOR_DEBUG"]
        # Yield an initialization message
        Ractor.yield({ type: :initialize, processor: name })

        # Instantiate the specific worker inside the Ractor
        worker = worker_cls.new(name: name)

        loop do
          # Ractor.receive will block until a message is received
          puts "Waiting for work in #{name}" if ENV["FRACTOR_DEBUG"]
          work = Ractor.receive

          # Handle shutdown message
          if work == :shutdown
            puts "Received shutdown message in Ractor #{name}, terminating..." if ENV["FRACTOR_DEBUG"]
            # Yield a shutdown acknowledgment before terminating
            Ractor.yield({ type: :shutdown, processor: name })
            break
          end

          puts "Received work #{work.inspect} in #{name}" if ENV["FRACTOR_DEBUG"]

          begin
            # Process the work using the instantiated worker
            result = worker.process(work)
            puts "Sending result #{result.inspect} from Ractor #{name}" if ENV["FRACTOR_DEBUG"]
            # Wrap the result in a WorkResult object if not already wrapped
            work_result = if result.is_a?(Fractor::WorkResult)
                            result
                          else
                            Fractor::WorkResult.new(result: result, work: work)
                          end
            # Yield the result back
            Ractor.yield({ type: :result, result: work_result,
                           processor: name })
          rescue StandardError => e
            # Handle errors during processing
            puts "Error processing work #{work.inspect} in Ractor #{name}: #{e.message}\n#{e.backtrace.join("\n")}" if ENV["FRACTOR_DEBUG"]
            # Yield an error message back
            # Ensure the original work object is included in the error result
            error_result = Fractor::WorkResult.new(error: e.message, work: work)
            Ractor.yield({ type: :error, result: error_result,
                           processor: name })
          end
        end
      rescue Ractor::ClosedError
        puts "Ractor #{name} closed." if ENV["FRACTOR_DEBUG"]
      rescue StandardError => e
        puts "Unexpected error in Ractor #{name}: #{e.message}\n#{e.backtrace.join("\n")}" if ENV["FRACTOR_DEBUG"]
        # Optionally yield a critical error message if needed
      ensure
        puts "Ractor #{name} shutting down." if ENV["FRACTOR_DEBUG"]
      end
      puts "Ractor #{@name} instance created: #{@ractor}" if ENV["FRACTOR_DEBUG"]
    end

    # Sends work to the Ractor if it's active.
    def send(work)
      if @ractor
        begin
          @ractor.send(work)
          true
        rescue Exception => e
          puts "Warning: Error sending work to Ractor #{@name}: #{e.message}" if ENV["FRACTOR_DEBUG"]
          false
        end
      else
        puts "Warning: Attempted to send work to nil Ractor #{@name}" if ENV["FRACTOR_DEBUG"]
        false
      end
    end

    # Closes the Ractor.
    # Ruby 3.0+ has different ways to terminate Ractors, we try the available methods
    def close
      return true if @ractor.nil?

      begin
        # Send a nil message to signal we're done - this might be processed
        # if the Ractor is waiting for input
        begin
          begin
            @ractor.send(nil)
          rescue StandardError
            nil
          end
        rescue StandardError
          # Ignore errors when sending nil
        end

        # Mark as closed in our object
        old_ractor = @ractor
        @ractor = nil

        # If available in this Ruby version, we'll try kill
        if old_ractor.respond_to?(:kill)
          begin
            old_ractor.kill
          rescue StandardError
            nil
          end
        end

        true
      rescue Exception => e
        puts "Warning: Error closing Ractor #{@name}: #{e.message}" if ENV["FRACTOR_DEBUG"]
        # Consider it closed even if there was an error
        @ractor = nil
        true
      end
    end

    # Checks if the Ractor is closed or unavailable.
    def closed?
      return true if @ractor.nil?

      begin
        # Check if the Ractor is terminated using Ractor#inspect
        # This is safer than calling methods on the Ractor
        r_status = @ractor.inspect
        if r_status.include?("terminated")
          # If terminated, clean up our reference
          @ractor = nil
          return true
        end
        false
      rescue Exception => e
        # If we get an exception, the Ractor is likely terminated
        puts "Ractor #{@name} appears to be terminated: #{e.message}" if ENV["FRACTOR_DEBUG"]
        @ractor = nil
        true
      end
    end
  end
end
