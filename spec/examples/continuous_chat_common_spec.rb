# frozen_string_literal: true

require_relative "../../examples/continuous_chat_common/message_protocol"

RSpec.describe "Continuous Chat Common" do
  describe "MessagePacket" do
    let(:data) { { username: "alice", message: "Hello" } }
    let(:packet) { ContinuousChat::MessagePacket.new(:chat, data) }

    describe "initialization" do
      it "creates a packet with type, data, and timestamp" do
        expect(packet.type).to eq(:chat)
        expect(packet.data).to eq(data)
        expect(packet.timestamp).to be_a(Integer)
      end

      it "accepts custom timestamp" do
        custom_time = Time.now.to_i - 1000
        custom_packet = ContinuousChat::MessagePacket.new(:chat, data,
                                                          custom_time)

        expect(custom_packet.timestamp).to eq(custom_time)
      end

      it "converts type to symbol" do
        packet = ContinuousChat::MessagePacket.new("server_message", data)

        expect(packet.type).to be_a(Symbol)
        expect(packet.type).to eq(:server_message)
      end
    end

    describe "to_json" do
      it "serializes to JSON format" do
        json = packet.to_json
        parsed = JSON.parse(json)

        expect(parsed["type"]).to eq("chat")
        # JSON returns string keys, not symbol keys
        expect(parsed["data"]).to eq("message" => "Hello",
                                     "username" => "alice")
        expect(parsed["timestamp"]).to be_a(Integer)
      end

      it "includes all required fields" do
        json = packet.to_json
        parsed = JSON.parse(json)

        expect(parsed.keys).to contain_exactly("type", "data", "timestamp")
      end
    end

    describe "to_s" do
      it "returns JSON string representation" do
        str = packet.to_s

        expect(str).to be_a(String)
        parsed = JSON.parse(str)
        expect(parsed["type"]).to eq("chat")
      end
    end
  end

  describe "MessageProtocol" do
    describe ".create_packet" do
      it "creates a JSON packet from type and data" do
        json = ContinuousChat::MessageProtocol.create_packet(:join,
                                                             { username: "bob" })

        expect(json).to be_a(String)
        parsed = JSON.parse(json)
        expect(parsed["type"]).to eq("join")
        expect(parsed["data"]["username"]).to eq("bob")
      end

      it "includes timestamp in created packet" do
        json = ContinuousChat::MessageProtocol.create_packet(:chat,
                                                             { message: "hi" })
        parsed = JSON.parse(json)

        expect(parsed["timestamp"]).to be_a(Integer)
      end
    end

    describe ".parse_packet" do
      it "parses JSON string into MessagePacket" do
        json = { type: "chat", data: { message: "hello" },
                 timestamp: Time.now.to_i }.to_json
        packet = ContinuousChat::MessageProtocol.parse_packet(json)

        expect(packet).to be_a(ContinuousChat::MessagePacket)
        expect(packet.type).to eq(:chat)
        # JSON returns string keys, not symbol keys
        expect(packet.data).to eq("message" => "hello")
      end

      it "converts type to symbol" do
        json = { type: "server_message", data: {},
                 timestamp: Time.now.to_i }.to_json
        packet = ContinuousChat::MessageProtocol.parse_packet(json)

        expect(packet.type).to eq(:server_message)
      end

      it "returns nil for invalid JSON" do
        packet = ContinuousChat::MessageProtocol.parse_packet("invalid json")

        expect(packet).to be_nil
      end

      it "handles JSON parsing errors gracefully" do
        packet = ContinuousChat::MessageProtocol.parse_packet("{ invalid json }")

        expect(packet).to be_nil
      end

      it "uses current time for missing timestamp" do
        before_time = Time.now.to_i
        json = { type: "chat", data: {} }.to_json
        packet = ContinuousChat::MessageProtocol.parse_packet(json)
        after_time = Time.now.to_i

        expect(packet.timestamp).to be_between(before_time, after_time)
      end
    end

    describe "round-trip serialization" do
      it "can serialize and deserialize packets correctly" do
        original = ContinuousChat::MessagePacket.new(:chat,
                                                     { username: "alice",
                                                       message: "Hi!" })
        json = original.to_json
        parsed = ContinuousChat::MessageProtocol.parse_packet(json)

        expect(parsed.type).to eq(original.type)
        # JSON returns string keys, not symbol keys
        expect(parsed.data).to eq("username" => "alice", "message" => "Hi!")
        expect(parsed.timestamp).to eq(original.timestamp)
      end
    end
  end

  describe "message types" do
    it "supports join messages" do
      json = ContinuousChat::MessageProtocol.create_packet(:join,
                                                           { username: "user1" })
      packet = ContinuousChat::MessageProtocol.parse_packet(json)

      expect(packet.type).to eq(:join)
      # JSON returns string keys, not symbol keys
      expect(packet.data["username"]).to eq("user1")
    end

    it "supports chat messages" do
      json = ContinuousChat::MessageProtocol.create_packet(:chat,
                                                           { message: "Hello everyone" })
      packet = ContinuousChat::MessageProtocol.parse_packet(json)

      expect(packet.type).to eq(:chat)
      expect(packet.data["message"]).to eq("Hello everyone")
    end

    it "supports server_message type" do
      json = ContinuousChat::MessageProtocol.create_packet(:server_message,
                                                           { message: "Welcome!" })
      packet = ContinuousChat::MessageProtocol.parse_packet(json)

      expect(packet.type).to eq(:server_message)
      expect(packet.data["message"]).to eq("Welcome!")
    end

    it "supports user_list type" do
      users = %w[alice bob charlie]
      json = ContinuousChat::MessageProtocol.create_packet(:user_list,
                                                           { users: users })
      packet = ContinuousChat::MessageProtocol.parse_packet(json)

      expect(packet.type).to eq(:user_list)
      expect(packet.data["users"]).to eq(users)
    end
  end

  describe "complex data structures" do
    it "handles nested data structures" do
      complex_data = {
        user: { name: "Alice", id: 123,
                metadata: { role: "admin", joined_at: "2024-01-01" } },
        message: { content: "Hello", format: "markdown" },
      }
      json = ContinuousChat::MessageProtocol.create_packet(:chat, complex_data)
      packet = ContinuousChat::MessageProtocol.parse_packet(json)

      # JSON returns string keys, not symbol keys
      expect(packet.data["user"]["name"]).to eq("Alice")
      expect(packet.data["user"]["metadata"]["role"]).to eq("admin")
      expect(packet.data["message"]["format"]).to eq("markdown")
    end

    it "handles array data" do
      array_data = {
        messages: [
          { id: 1, text: "First", sender: "alice" },
          { id: 2, text: "Second", sender: "bob" },
        ],
      }
      json = ContinuousChat::MessageProtocol.create_packet(:history, array_data)
      packet = ContinuousChat::MessageProtocol.parse_packet(json)

      # JSON returns string keys, not symbol keys
      expect(packet.data["messages"].size).to eq(2)
      expect(packet.data["messages"].first["text"]).to eq("First")
    end
  end

  describe "timestamp handling" do
    it "preserves timestamps through serialization" do
      original_time = Time.now.to_i
      packet1 = ContinuousChat::MessagePacket.new(:chat, {}, original_time)
      json = packet1.to_json
      packet2 = ContinuousChat::MessageProtocol.parse_packet(json)

      expect(packet2.timestamp).to eq(original_time)
    end

    it "handles timestamps as Unix epoch integers" do
      time = Time.now.to_i
      json = { type: "chat", data: {}, timestamp: time }.to_json
      packet = ContinuousChat::MessageProtocol.parse_packet(json)

      expect(packet.timestamp).to be_a(Integer)
      expect(packet.timestamp).to eq(time)
    end
  end
end
