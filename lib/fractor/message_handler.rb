# frozen_string_literal: true

module Fractor
  class MessageHandler
    def initialize
      @handlers = {}
    end

    def register(message_type, &handler)
      @handlers[message_type] = handler
    end

    def handle(message)
      handler = @handlers[message.type]

      if handler
        handler.call(message.params)
      else
        raise "No handler registered for message type: #{message.type}"
      end
    end

    def known_message_types
      @handlers.keys
    end
  end
end
