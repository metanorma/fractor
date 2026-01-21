# frozen_string_literal: true

module Fractor
  # Base class for wrapped Ractors with shared functionality.
  # Subclasses implement Ruby 3.x and Ruby 4.0+ specific communication patterns.
  class WrappedRactor
    attr_reader :ractor, :name, :worker_class

    # Factory method to create the appropriate WrappedRactor implementation
    # based on the current Ruby version.
    #
    # @param name [String] Name for the ractor
    # @param worker_class [Class] Worker class to instantiate
    # @param kwargs [Hash] Additional keyword arguments for subclass initialization
    # @return [WrappedRactor] The appropriate subclass instance
    def self.create(name, worker_class, **kwargs)
      ruby_4_0 = Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("4.0.0")
      if ruby_4_0
        WrappedRactor4.new(name, worker_class, **kwargs)
      else
        WrappedRactor3.new(name, worker_class, **kwargs)
      end
    end

    # Initializes the WrappedRactor with a name and the Worker class.
    #
    # @param name [String] Name for the ractor
    # @param worker_class [Class] Worker class to instantiate
    def initialize(name, worker_class)
      puts "Creating Ractor #{name} with worker #{worker_class}" if ENV["FRACTOR_DEBUG"]
      @name = name
      @worker_class = worker_class
      @ractor = nil
    end

    # Starts the underlying Ractor. Must be implemented by subclasses.
    def start
      raise NotImplementedError, "Subclasses must implement #start"
    end

    # Sends work to the Ractor. Must be implemented by subclasses.
    #
    # @param work [Fractor::Work] The work item to process
    # @return [Boolean] true if sent successfully, false otherwise
    def send(work)
      raise NotImplementedError, "Subclasses must implement #send"
    end

    # Receives a message from the Ractor. Must be implemented by subclasses.
    #
    # @return [Hash, nil] The message received or nil
    def receive_message
      raise NotImplementedError, "Subclasses must implement #receive_message"
    end

    # Closes the Ractor.
    #
    # @return [Boolean] true if closed successfully
    def close
      return true if @ractor.nil?

      begin
        # Send a nil message to signal we're done
        begin
          @ractor.send(nil)
        rescue StandardError
          nil
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
    # Uses a timeout to avoid blocking on Windows Ruby 3.4 where
    # Ractor#inspect can block if the ractor is waiting on receive.
    #
    # @return [Boolean] true if closed, false otherwise
    def closed?
      return true if @ractor.nil?

      # Use a timeout to avoid blocking indefinitely on Windows Ruby 3.4
      result = Timeout.timeout(0.1) do
        @ractor.inspect
      rescue Timeout::Error
        # Timeout means ractor is still running (not terminated)
        "#<Ractor:blocked>"
      end

      if result.include?("terminated")
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
