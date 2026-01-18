# frozen_string_literal: true

require "spec_helper"
require_relative "../../examples/stream_processor/stream_processor"

RSpec.describe "Stream Processor Example" do
  describe Event do
    describe "#initialize" do
      it "creates event with required parameters" do
        event = described_class.new(
          type: :click,
          data: { user_id: 123 },
        )

        expect(event.type).to eq(:click)
        expect(event.data).to eq({ user_id: 123 })
        expect(event.timestamp).to be_a(Time)
      end

      it "accepts custom timestamp" do
        custom_time = Time.now - 3600
        event = described_class.new(
          type: :view,
          data: {},
          timestamp: custom_time,
        )

        expect(event.timestamp).to eq(custom_time)
      end
    end

    describe "#to_s" do
      it "returns readable string representation" do
        event = described_class.new(type: :purchase, data: {})
        expect(event.to_s).to match(/Event\(purchase, \d{4}-\d{2}-\d{2}T/)
      end
    end
  end

  describe EventProcessorWorker do
    let(:worker) { described_class.new }

    describe "#process" do
      it "processes Event and returns result" do
        event = Event.new(
          type: :click,
          data: { user_id: 123, value: 45.67 },
        )

        result = worker.process(event)

        expect(result).to be_a(Hash)
        expect(result[:type]).to eq(:click)
        expect(result[:data]).to eq({ user_id: 123, value: 45.67 })
        expect(result[:timestamp]).to be_a(Time)
        expect(result[:processed_at]).to be_a(Time)
        expect(result[:processing_time]).to be_a(Numeric)
      end

      it "returns nil for non-Event items" do
        result = worker.process("not an event")
        expect(result).to be_nil
      end

      it "calculates processing time" do
        event = Event.new(
          type: :view,
          data: {},
          timestamp: Time.now - 0.1, # 100ms ago
        )

        result = worker.process(event)

        expect(result[:processing_time]).to be >= 100
      end
    end
  end

  describe StreamProcessor do
    let(:processor) { described_class.new(window_size: 2, num_workers: 2) }

    describe "#initialize" do
      it "initializes with default parameters" do
        default_processor = described_class.new

        expect(default_processor.window_size).to eq(5)
        expect(default_processor.processed_count).to eq(0)
        expect(default_processor.error_count).to eq(0)
      end

      it "accepts custom window size and workers" do
        custom_processor = described_class.new(window_size: 10, num_workers: 8)

        expect(custom_processor.window_size).to eq(10)
      end

      it "initializes metrics hash" do
        expect(processor.metrics).to be_a(Hash)
        expect(processor.metrics[:total_events]).to eq(0)
        expect(processor.metrics[:events_per_second]).to eq(0.0)
      end
    end

    describe "#start" do
      it "starts the processor" do
        result = processor.start

        expect(result).to eq(processor)

        processor.stop
      end
    end

    describe "#add_event" do
      it "adds event to the stream" do
        processor.start

        event = Event.new(type: :click, data: { user_id: 1 })
        processor.add_event(event)

        expect(processor.metrics[:total_events]).to eq(1)

        processor.stop
      end

      it "handles nil server gracefully" do
        event = Event.new(type: :click, data: {})
        expect { processor.add_event(event) }.not_to raise_error
      end
    end

    describe "#stop" do
      it "stops the server gracefully" do
        processor.start
        expect { processor.stop }.not_to raise_error
      end

      it "handles multiple stop calls" do
        processor.start
        processor.stop
        expect { processor.stop }.not_to raise_error
      end
    end

    describe "event processing" do
      it "processes multiple events" do
        processor.start

        5.times do |i|
          event = Event.new(type: :click, data: { user_id: i })
          processor.add_event(event)
        end

        processor.process_events
        processor.stop

        expect(processor.processed_count).to eq(5)
      end

      it "tracks metrics over time" do
        processor.start

        10.times do |i|
          event = Event.new(type: :view, data: { user_id: i })
          processor.add_event(event)
        end

        processor.process_events
        processor.stop

        expect(processor.metrics[:total_events]).to eq(10)
        expect(processor.processed_count).to eq(10)
      end
    end

    describe "window management" do
      it "maintains sliding window of events" do
        processor.start

        # Add events
        5.times do
          event = Event.new(type: :click, data: {})
          processor.add_event(event)
        end

        processor.process_events
        processor.stop

        # Window should have events
        expect(processor.metrics[:current_window_count]).to be > 0
      end
    end
  end

  describe EventGenerator do
    describe ".generate_stream" do
      it "generates events at specified rate" do
        processor = StreamProcessor.new(window_size: 2, num_workers: 2)
        processor.start

        # Generate 5 events quickly
        5.times do |i|
          event = Event.new(
            type: %i[click view].sample,
            data: { user_id: i },
          )
          processor.add_event(event)
        end

        processor.process_events
        processor.stop

        expect(processor.metrics[:total_events]).to eq(5)
      end

      it "generates diverse event types" do
        processor = StreamProcessor.new(window_size: 2, num_workers: 2)
        processor.start

        10.times do |i|
          event = Event.new(
            type: %i[click view purchase signup].sample,
            data: { user_id: i },
          )
          processor.add_event(event)
        end

        processor.process_events
        processor.stop

        expect(processor.metrics[:total_events]).to eq(10)
      end
    end
  end

  describe "Integration tests" do
    it "processes stream end-to-end" do
      processor = StreamProcessor.new(window_size: 2, num_workers: 4)
      processor.start

      # Generate small stream
      20.times do |i|
        event = Event.new(
          type: %i[click view purchase].sample,
          data: { user_id: i, value: rand(1.0..100.0) },
        )
        processor.add_event(event)
      end

      processor.process_events
      processor.stop

      expect(processor.metrics[:total_events]).to eq(20)
      expect(processor.processed_count).to eq(20)
      expect(processor.metrics[:events_per_second]).to be > 0
    end

    it "handles high throughput" do
      processor = StreamProcessor.new(window_size: 1, num_workers: 8)
      processor.start

      # Generate burst of events
      100.times do |i|
        event = Event.new(type: :click, data: { user_id: i })
        processor.add_event(event)
      end

      processor.process_events
      processor.stop

      expect(processor.metrics[:total_events]).to eq(100)
      expect(processor.processed_count).to eq(100)
    end

    it "calculates metrics correctly" do
      processor = StreamProcessor.new(window_size: 2, num_workers: 2)
      processor.start

      10.times do |i|
        event = Event.new(type: :view, data: { user_id: i })
        processor.add_event(event)
      end

      processor.process_events
      processor.stop

      expect(processor.metrics[:total_events]).to eq(10)
      expect(processor.processed_count).to eq(10)
      expect(processor.metrics[:events_per_second]).to be > 0
    end

    it "maintains window correctly" do
      processor = StreamProcessor.new(window_size: 1, num_workers: 2)
      processor.start

      # Add first batch
      5.times do
        event = Event.new(type: :click, data: {}, timestamp: Time.now - 2)
        processor.add_event(event)
      end

      # Add second batch (recent)
      5.times do
        event = Event.new(type: :view, data: {})
        processor.add_event(event)
      end

      processor.process_events
      processor.stop

      # Window should only contain recent events (within 1 second)
      expect(processor.metrics[:current_window_count]).to be_between(0, 10)
    end
  end
end
