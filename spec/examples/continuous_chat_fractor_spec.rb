# frozen_string_literal: true

require_relative "../../examples/continuous_chat_fractor/chat_common"

RSpec.describe "Continuous Chat Fractor Example" do
  describe ContinuousChat::MessagePacket do
    it "stores type, data, and timestamp" do
      packet = described_class.new(:broadcast, { message: "hello" }, 123456)
      expect(packet.type).to eq(:broadcast)
      expect(packet.data).to eq({ message: "hello" })
      expect(packet.timestamp).to eq(123456)
    end

    it "defaults timestamp to current time" do
      packet = described_class.new(:broadcast, { message: "hello" })
      expect(packet.timestamp).to be_a(Integer)
      expect(packet.timestamp).to be > 0
    end

    it "converts type to symbol" do
      packet = described_class.new("broadcast", { message: "hello" })
      expect(packet.type).to eq(:broadcast)
    end

    it "converts to JSON" do
      packet = described_class.new(:broadcast, { message: "hello" }, 123456)
      json = packet.to_json
      expect(json).to be_a(String)
      expect(json).to include("broadcast")
    end
  end

  describe ContinuousChat::MessageProtocol do
    it "creates a packet" do
      json = described_class.create_packet(:broadcast, { message: "hello" })
      expect(json).to be_a(String)
      expect(json).to include("broadcast")
    end

    it "parses a packet" do
      json = '{"type":"broadcast","data":{"message":"hello"},"timestamp":123456}'
      packet = described_class.parse_packet(json)

      expect(packet).to be_a(ContinuousChat::MessagePacket)
      expect(packet.type).to eq(:broadcast)
      expect(packet.data["message"]).to eq("hello")
      expect(packet.timestamp).to eq(123456)
    end

    it "handles invalid JSON gracefully" do
      packet = described_class.parse_packet("invalid json")
      expect(packet).to be_nil
    end
  end

  describe ContinuousChatFractor::ChatMessage do
    let(:packet) { ContinuousChat::MessagePacket.new(:broadcast, { from: "user1", content: "hello" }) }

    it "stores packet and client_socket" do
      work = described_class.new(packet, "socket")
      expect(work.packet).to eq(packet)
      expect(work.client_socket).to eq("socket")
    end

    it "provides a string representation" do
      work = described_class.new(packet)
      expect(work.to_s).to include("ChatMessage", "broadcast")
    end
  end

  describe ContinuousChatFractor::ChatWorker do
    let(:worker) { described_class.new }

    context "processing broadcast messages" do
      it "processes broadcast messages" do
        packet = ContinuousChat::MessagePacket.new(:broadcast,
                                                   { from: "user1",
                                                     content: "hello" })
        work = ContinuousChatFractor::ChatMessage.new(packet)
        result = worker.process(work)

        expect(result).to be_a(Fractor::WorkResult)
        expect(result.success?).to be true
        expect(result.result[:action]).to eq(:broadcast)
        expect(result.result[:from]).to eq("user1")
        expect(result.result[:content]).to eq("hello")
      end
    end

    context "processing direct messages" do
      it "processes direct messages" do
        packet = ContinuousChat::MessagePacket.new(:direct_message,
                                                   { from: "user1",
                                                     to: "user2", content: "hi" })
        work = ContinuousChatFractor::ChatMessage.new(packet)
        result = worker.process(work)

        expect(result.success?).to be true
        expect(result.result[:action]).to eq(:direct_message)
        expect(result.result[:from]).to eq("user1")
        expect(result.result[:to]).to eq("user2")
        expect(result.result[:content]).to eq("hi")
      end
    end

    context "processing server messages" do
      it "processes server messages" do
        packet = ContinuousChat::MessagePacket.new(:server_message,
                                                   { message: "Server update" })
        work = ContinuousChatFractor::ChatMessage.new(packet)
        result = worker.process(work)

        expect(result.success?).to be true
        expect(result.result[:action]).to eq(:server_message)
        expect(result.result[:message]).to eq("Server update")
      end
    end

    context "processing user list updates" do
      it "processes user list updates" do
        packet = ContinuousChat::MessagePacket.new(:user_list,
                                                   { users: ["user1",
                                                             "user2"] })
        work = ContinuousChatFractor::ChatMessage.new(packet)
        result = worker.process(work)

        expect(result.success?).to be true
        expect(result.result[:action]).to eq(:user_list)
        expect(result.result[:users]).to eq(["user1", "user2"])
      end
    end

    context "processing unknown message types" do
      it "handles unknown message types" do
        packet = ContinuousChat::MessagePacket.new(:unknown_type,
                                                   { data: "test" })
        work = ContinuousChatFractor::ChatMessage.new(packet)
        result = worker.process(work)

        expect(result.success?).to be true
        expect(result.result[:action]).to eq(:error)
        expect(result.result[:message]).to include("Unknown message type")
      end
    end
  end
end
