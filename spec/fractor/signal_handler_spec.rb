# frozen_string_literal: true

require "spec_helper"

RSpec.describe Fractor::SignalHandler do
  let(:continuous_mode) { false }
  let(:handler) { described_class.new(continuous_mode: continuous_mode, debug: false) }

  describe "#initialize" do
    it "stores continuous mode setting" do
      expect(handler.instance_variable_get(:@continuous_mode)).to eq(continuous_mode)
    end

    it "stores debug setting" do
      expect(handler.instance_variable_get(:@debug)).to be false
    end
  end

  describe "#setup" do
    it "sets up signal handlers without error" do
      expect { handler.setup }.not_to raise_error
    end
  end

  describe "with callbacks" do
    let(:status_called) { [] }
    let(:shutdown_called) { [] }

    let(:handler) do
      described_class.new(
        continuous_mode: false,
        debug: false,
        status_callback: -> { status_called << true },
        shutdown_callback: ->(mode) { shutdown_called << mode }
      )
    end

    it "accepts status callback" do
      expect(handler.instance_variable_get(:@status_callback)).to be_a(Proc)
    end

    it "accepts shutdown callback" do
      expect(handler.instance_variable_get(:@shutdown_callback)).to be_a(Proc)
    end
  end
end
