#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "time"

module ContinuousChat
  # Message packet class for handling protocol messages
  class MessagePacket
    attr_reader :type, :data, :timestamp

    def initialize(type, data, timestamp = Time.now.to_i)
      @type = type.to_sym
      @data = data
      @timestamp = timestamp
    end

    # Convert to JSON string
    def to_json(*_args)
      {
        type: @type,
        data: @data,
        timestamp: @timestamp,
      }.to_json
    end

    # String representation
    def to_s
      to_json
    end
  end

  # Helper module for message protocol
  module MessageProtocol
    # Create a packet of the given type with data
    def self.create_packet(type, data)
      MessagePacket.new(type, data).to_json
    end

    # Parse a JSON string into a message packet
    def self.parse_packet(json_string)
      data = JSON.parse(json_string)
      type = data["type"]&.to_sym
      content = data["data"] || {}
      timestamp = data["timestamp"] || Time.now.to_i

      MessagePacket.new(type, content, timestamp)
    rescue JSON::ParserError => e
      puts "Error parsing message: #{e.message}"
      nil
    end
  end
end
