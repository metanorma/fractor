#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../continuous_chat_common/message_protocol'
require_relative '../../lib/fractor'

module ContinuousChatFractor
  # ChatMessage represents a chat message as a unit of work for Fractor
  class ChatMessage < Fractor::Work
    def initialize(packet, client_socket = nil)
      super({ packet: packet, client_socket: client_socket })
    end

    def packet
      input[:packet]
    end

    def client_socket
      input[:client_socket]
    end

    def to_s
      "ChatMessage: #{packet.type} from #{packet.data}"
    end
  end

  # ChatWorker processes chat messages using Fractor
  class ChatWorker < Fractor::Worker
    def process(work)
      packet = work.packet
      work.client_socket

      # Process based on message type
      result = case packet.type
               when :broadcast
                 # Broadcast message processing
                 {
                   action: :broadcast,
                   from: packet.data[:from],
                   content: packet.data[:content],
                   timestamp: packet.timestamp
                 }
               when :direct_message
                 # Direct message processing
                 {
                   action: :direct_message,
                   from: packet.data[:from],
                   to: packet.data[:to],
                   content: packet.data[:content],
                   timestamp: packet.timestamp
                 }
               when :server_message
                 # Server message processing
                 {
                   action: :server_message,
                   message: packet.data[:message],
                   timestamp: packet.timestamp
                 }
               when :user_list
                 # User list update
                 {
                   action: :user_list,
                   users: packet.data[:users],
                   timestamp: packet.timestamp
                 }
               else
                 # Unknown message type
                 {
                   action: :error,
                   message: "Unknown message type: #{packet.type}",
                   timestamp: packet.timestamp
                 }
               end

      Fractor::WorkResult.new(result: result, work: work)
    rescue StandardError => e
      Fractor::WorkResult.new(
        error: "Error processing message: #{e.message}",
        work: work
      )
    end
  end
end
