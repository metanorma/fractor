# frozen_string_literal: true

module Fractor
  class Worker
    attr_reader :id

    @@work_types_registry = {}
    @@message_handlers = {}

    class << self
      # Define the work types this worker can handle
      def work_type_accepted(types)
        @@work_types_registry[self] = Array(types)
      end

      # Retrieve work types for this worker class
      def accepted_work_types
        @@work_types_registry[self] || []
      end

      # Define a message handler
      def handle_message(type, &block)
        @@message_handlers[self] ||= {}
        @@message_handlers[self][type] = block
      end

      # Get all message handlers for this worker class
      def message_handlers
        @@message_handlers[self] || {}
      end
    end

    # Default message handlers
    handle_message :process do |params|
      work = params[:work]
      if self.class.accepted_work_types.include?(work.work_type)
        begin
          result = process_work(work)
          Ractor.yield(Message.new(type: :result, params: { result: result }))
        rescue => e
          error_data = {
            message: e.message,
            backtrace: e.backtrace,
            class: e.class.name
          }
          Ractor.yield(Message.new(type: :error, params: { work: work, error_details: error_data }))
        end
      else
        Ractor.yield(Message.new(type: :error, params: {
          work: work,
          error_details: {
            message: "Unsupported work type: #{work.work_type}",
            class: "UnsupportedWorkTypeError"
          }
        }))
      end
    end

    handle_message :terminate do |_|
      # Exit the ractor
      throw :terminate
    end

    handle_message :ping do |_|
      # Respond with pong
      Ractor.yield(Message.new(type: :pong, params: { worker_id: @id }))
    end

    def initialize
      @id = nil # Will be set by Supervisor when started
    end

    def start
      message_handlers = self.class.message_handlers
      accepted_types = self.class.accepted_work_types
      worker_class = self.class

      ractor = Ractor.new(message_handlers, accepted_types, @id, worker_class) do |handlers, work_types, worker_id, worker_class|
        Thread.current.name = "Fractor-Worker-#{worker_id}"

        # Create worker instance in Ractor
        worker_instance = worker_class.new
        worker_instance.instance_variable_set(:@id, worker_id)

        catch :terminate do
          loop do
            begin
              message_data = Ractor.receive
              message_type, params = message_data

              handler = handlers[message_type]
              if handler
                worker_instance.instance_exec(params, &handler)
              else
                Ractor.yield([:error, {
                  error_details: {
                    message: "Unknown message type: #{message_type}",
                    class: "UnknownMessageError"
                  }
                }])
              end
            rescue => e
              # Last resort error handling
              Ractor.yield([:fatal_error, {
                error_details: {
                  message: e.message,
                  backtrace: e.backtrace,
                  class: e.class.name
                }
              }])
            end
          end
        end
      end

      ractor
    end

    def process_work(work)
      # To be overridden by subclasses
      raise NotImplementedError, "Subclasses must implement process_work method"
    end
  end
end
