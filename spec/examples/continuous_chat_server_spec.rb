# frozen_string_literal: true

require_relative "../../examples/continuous_chat_common/message_protocol"

RSpec.describe "Continuous Chat Server" do
  # Note: This spec tests the server logic without actually starting
  # a TCP server, which would require integration testing.

  describe "server message protocol" do
    it "parses join messages correctly" do
      message = {
        type: "join",
        data: { username: "alice" },
        timestamp: Time.now.to_i,
      }.to_json

      packet = ContinuousChat::MessageProtocol.parse_packet(message)

      expect(packet.type).to eq(:join)
      expect(packet.data["username"]).to eq("alice")
    end

    it "parses chat messages correctly" do
      message = {
        type: "chat",
        data: { message: "Hello everyone!" },
        timestamp: Time.now.to_i,
      }.to_json

      packet = ContinuousChat::MessageProtocol.parse_packet(message)

      expect(packet.type).to eq(:chat)
      expect(packet.data["message"]).to eq("Hello everyone!")
    end
  end

  describe "message types" do
    describe "join message" do
      it "contains username in data" do
        join_msg = ContinuousChat::MessageProtocol.create_packet(:join, { username: "test_user" })

        parsed = JSON.parse(join_msg)
        expect(parsed["type"]).to eq("join")
        expect(parsed["data"]["username"]).to eq("test_user")
      end
    end

    describe "server_message" do
      it "contains message content in data" do
        server_msg = ContinuousChat::MessageProtocol.create_packet(
          :server_message,
          { message: "Welcome to the chat!" },
        )

        parsed = JSON.parse(server_msg)
        expect(parsed["type"]).to eq("server_message")
        expect(parsed["data"]["message"]).to eq("Welcome to the chat!")
      end
    end

    describe "user_list message" do
      it "contains array of usernames" do
        user_list_msg = ContinuousChat::MessageProtocol.create_packet(
          :user_list,
          { users: %w[alice bob charlie] },
        )

        parsed = JSON.parse(user_list_msg)
        expect(parsed["type"]).to eq("user_list")
        expect(parsed["data"]["users"]).to eq(%w[alice bob charlie])
      end
    end

    describe "chat message" do
      it "contains message content" do
        chat_msg = ContinuousChat::MessageProtocol.create_packet(
          :chat,
          { username: "alice", message: "Hi bob!" },
        )

        parsed = JSON.parse(chat_msg)
        expect(parsed["type"]).to eq("chat")
        expect(parsed["data"]["username"]).to eq("alice")
        expect(parsed["data"]["message"]).to eq("Hi bob!")
      end
    end
  end

  describe "message structure" do
    it "includes all required fields" do
      packet = ContinuousChat::MessagePacket.new(:chat, { text: "Hello" })
      json = packet.to_json
      parsed = JSON.parse(json)

      expect(parsed.keys).to contain_exactly("type", "data", "timestamp")
    end

    it "converts type to string in JSON" do
      packet = ContinuousChat::MessagePacket.new(:chat, {})
      json = packet.to_json
      parsed = JSON.parse(json)

      expect(parsed["type"]).to be_a(String)
      expect(parsed["type"]).to eq("chat")
    end
  end

  describe "protocol validation" do
    it "handles messages with missing data gracefully" do
      message = { type: "chat", timestamp: Time.now.to_i }.to_json
      packet = ContinuousChat::MessageProtocol.parse_packet(message)

      expect(packet).to be_a(ContinuousChat::MessagePacket)
      expect(packet.data).to eq({})
    end

    it "handles messages with missing timestamp" do
      message = { type: "chat", data: {} }.to_json
      before_time = Time.now.to_i
      packet = ContinuousChat::MessageProtocol.parse_packet(message)
      after_time = Time.now.to_i

      expect(packet.timestamp).to be_between(before_time, after_time)
    end
  end

  describe "message round-trip" do
    it "preserves data through serialize-deserialize cycle" do
      original_data = {
        username: "alice",
        message: "Hello!",
        metadata: { color: "blue", timestamp: Time.now.to_i },
      }

      packet = ContinuousChat::MessagePacket.new(:chat, original_data)
      json = packet.to_json
      restored_packet = ContinuousChat::MessageProtocol.parse_packet(json)

      expect(restored_packet.data).to eq(original_data)
      expect(restored_packet.type).to eq(:chat)
    end
  end

  describe "edge cases" do
    it "handles empty messages" do
      message = { type: "chat", data: {}, timestamp: Time.now.to_i }.to_json
      packet = ContinuousChat::MessageProtocol.parse_packet(message)

      expect(packet).to be_a(ContinuousChat::MessagePacket)
      expect(packet.data).to eq({})
    end

    it "handles messages with special characters" do
      special_text = "Hello! @user #hashtag $money %percent ^caret &ampersand *asterisk"
      message = {
        type: "chat",
        data: { message: special_text },
        timestamp: Time.now.to_i,
      }.to_json
      packet = ContinuousChat::MessageProtocol.parse_packet(message)

      expect(packet.data["message"]).to eq(special_text)
    end

    it "handles unicode characters" do
      unicode_text = "Hello 世界 🌍 مرحبا"
      message = {
        type: "chat",
        data: { message: unicode_text },
        timestamp: Time.now.to_i,
      }.to_json
      packet = ContinuousChat::MessageProtocol.parse_packet(message)

      expect(packet.data["message"]).to eq(unicode_text)
    end

    it "handles very long messages" do
      long_text = "A" * 10000
      message = {
        type: "chat",
        data: { message: long_text },
        timestamp: Time.now.to_i,
      }.to_json
      packet = ContinuousChat::MessageProtocol.parse_packet(message)

      expect(packet.data["message].length).to eq(10000)
    end
  end

  describe "MessageProtocol helper methods" do
    describe ".create_packet" do
      it "is a convenient factory for creating packets" do
        json = ContinuousChat::MessageProtocol.create_packet(:test, { key: "value" })
        parsed = JSON.parse(json)

        expect(parsed["type"]).to eq("test")
        expect(parsed["data"]["key"]).to eq("value")
        expect(parsed["timestamp"]).to be_a(Integer)
      end
    end

    describe ".parse_packet" do
      it "is a convenient parser for JSON strings" do
        json = { type: "test", data: { key: "value" }, timestamp: Time.now.to_i }.to_json
        packet = ContinuousChat::MessageProtocol.parse_packet(json)

        expect(packet).to be_a(ContinuousChat::MessagePacket)
        expect(packet.type).to eq(:test)
      end

      it "returns nil for invalid JSON" do
        result = ContinuousChat::MessageProtocol.parse_packet("not valid json")

        expect(result).to be_nil
      end
    end
  end

  describe "timestamp consistency" do
    it "maintains timestamp consistency across multiple messages" do
      time = Time.now.to_i

      packet1 = ContinuousChat::MessagePacket.new(:chat, {}, time)
      packet2 = ContinuousChat::MessagePacket.new(:chat, {}, time)

      expect(packet1.timestamp).to eq(packet2.timestamp).to eq(time)
    end

    it "creates unique timestamps when not specified" do
      packet1 = ContinuousChat::MessagePacket.new(:chat, {})
      sleep 0.001
      packet2 = ContinuousChat::MessagePacket.new(:chat, {})

      expect(packet2.timestamp).to be > packet1.timestamp
    end
  end

  describe "complex real-world scenarios" do
    it "handles user joining and receiving user list" do
      # User joins
      join_msg = ContinuousChat::MessageProtocol.create_packet(:join, { username: "alice" })
      join_packet = ContinuousChat::MessageProtocol.parse_packet(join_msg)

      expect(join_packet.type).to eq(:join)

      # Server sends welcome
      welcome_msg = ContinuousChat::MessageProtocol.create_packet(
        :server_message,
        { message: "Hello alice! Connected clients: 1" },
      )
      welcome_packet = ContinuousChat::MessageProtocol.parse_packet(welcome_msg)

      expect(welcome_packet.data["message"]).to include("alice")

      # Server sends user list
      user_list_msg = ContinuousChat::MessageProtocol.create_packet(
        :user_list,
        { users: ["alice"] },
      )
      user_list_packet = ContinuousChat::MessageProtocol.parse_packet(user_list_msg)

      expect(user_list_packet.data["users"]).to eq(["alice"])
    end

    it "handles broadcast message" do
      broadcast_msg = ContinuousChat::MessageProtocol.create_packet(
        :server_message,
        { message: "alice joined the chat!" },
      )
      packet = ContinuousChat::MessageProtocol.parse_packet(broadcast_msg)

      expect(packet.data["message"]).to include("alice joined")
    end

    it "handles chat message with metadata" do
      chat_msg = ContinuousChat::MessageProtocol.create_packet(
        :chat,
        {
          username: "alice",
          message: "Hello bob!",
          timestamp: Time.now.to_i,
          color: "blue",
        },
      )
      packet = ContinuousChat::MessageProtocol.parse_packet(chat_msg)

      expect(packet.data["username"]).to eq("alice")
      expect(packet.data["message"]).to eq("Hello bob!")
      expect(packet.data["color"]).to eq("blue")
    end
  end
end
