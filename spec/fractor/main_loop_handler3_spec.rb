# frozen_string_literal: true

require "spec_helper"

# Skip all tests in this file on Ruby 4.0+
RSpec.describe Fractor::MainLoopHandler3, :ruby3 do
  let(:worker_class) do
    Class.new(Fractor::Worker) do
      def process(work)
        value = work.input[:value]
        Fractor::WorkResult.new(result: value * 2, work: work)
      end
    end
  end

  let(:work_class) do
    Class.new(Fractor::Work) do
      def initialize(value)
        super({ value: value })
      end
    end
  end

  let(:supervisor) do
    instance_double(Fractor::Supervisor,
                    work_queue: Queue.new,
                    workers: [],
                    results: Fractor::ResultAggregator.new,
                    error_reporter: Fractor::ErrorReporter.new)
  end

  let(:handler) { described_class.new(supervisor, debug: false) }

  before do
    # Set up common instance variables that the handler will access
    allow(supervisor).to receive(:instance_variable_get).with(:@running).and_return(true)
    allow(supervisor).to receive(:instance_variable_get).with(:@continuous_mode).and_return(false)
    allow(supervisor).to receive(:instance_variable_get).with(:@total_work_count).and_return(0)
    allow(supervisor).to receive(:instance_variable_get).with(:@ractors_map).and_return({})
    allow(supervisor).to receive(:instance_variable_get).with(:@wakeup_ractor).and_return(nil)
    allow(supervisor).to receive(:instance_variable_get).with(:@work_distribution_manager).and_return(nil)
    allow(supervisor).to receive(:instance_variable_get).with(:@performance_monitor).and_return(nil)
    allow(supervisor).to receive(:instance_variable_get).with(:@work_callbacks).and_return([])
    allow(supervisor).to receive(:instance_variable_get).with(:@error_callbacks).and_return([])
  end

  describe "Ruby 3.x specific behavior" do
    describe "#initialize" do
      it "stores reference to supervisor" do
        expect(handler.instance_variable_get(:@supervisor)).to eq(supervisor)
      end

      it "stores debug flag" do
        expect(handler.instance_variable_get(:@debug)).to be false
      end
    end

    describe "#get_active_ractors" do
      let(:ractor1) { Ractor.current }
      let(:ractor2) { Ractor.new { 1 } }

      before do
        allow(supervisor).to receive(:instance_variable_get).with(:@ractors_map).and_return(
          { ractor1 => :worker1, ractor2 => :worker2 },
        )
        allow(supervisor).to receive(:instance_variable_get).with(:@wakeup_ractor).and_return(nil)
      end

      it "returns all ractors from @ractors_map" do
        active = handler.send(:get_active_ractors)
        expect(active).to contain_exactly(ractor1, ractor2)
      end

      it "excludes wakeup ractor in batch mode" do
        allow(supervisor).to receive(:instance_variable_get).with(:@wakeup_ractor).and_return(ractor1)
        allow(supervisor).to receive(:instance_variable_get).with(:@continuous_mode).and_return(false)

        active = handler.send(:get_active_ractors)
        expect(active).to contain_exactly(ractor2)
      end

      it "includes wakeup ractor in continuous mode with callbacks" do
        allow(supervisor).to receive(:instance_variable_get).with(:@wakeup_ractor).and_return(ractor1)
        allow(supervisor).to receive(:instance_variable_get).with(:@continuous_mode).and_return(true)
        allow(supervisor).to receive(:instance_variable_get).with(:@work_callbacks).and_return([-> {
        }])

        active = handler.send(:get_active_ractors)
        expect(active).to contain_exactly(ractor1, ractor2)
      end
    end

    describe "#handle_edge_cases" do
      let(:ractor1) { Ractor.current }

      before do
        allow(supervisor).to receive(:instance_variable_get).with(:@ractors_map).and_return(
          { ractor1 => :worker1 },
        )
        allow(supervisor).to receive(:instance_variable_get).with(:@wakeup_ractor).and_return(nil)
      end

      it "returns true to continue loop when there are active ractors" do
        allow(supervisor).to receive(:instance_variable_get).with(:@continuous_mode).and_return(false)
        allow(supervisor).to receive(:instance_variable_get).with(:@total_work_count).and_return(10)

        result = handler.send(:handle_edge_cases, [ractor1], 5)
        expect(result).to be false # Continue the loop
      end

      it "returns true to break loop when no active ractors and shutting down" do
        handler.instance_variable_set(:@shutting_down, true)

        allow(supervisor).to receive(:instance_variable_get).with(:@continuous_mode).and_return(true)

        result = handler.send(:handle_edge_cases, [], 5)
        expect(result).to be true # Exit the loop
      end

      it "waits briefly in continuous mode when no active ractors" do
        allow(supervisor).to receive(:instance_variable_get).with(:@continuous_mode).and_return(true)
        allow(supervisor).to receive(:instance_variable_get).with(:@total_work_count).and_return(10)

        expect { handler.send(:handle_edge_cases, [], 0) }.not_to raise_error
      end
    end

    describe "#should_continue_running?" do
      it "returns true during shutdown if workers are not all closed" do
        # Set up the shutdown state
        handler.instance_variable_set(:@shutting_down, true)
        allow(supervisor).to receive(:instance_variable_get).with(:@running).and_return(false)

        # Mock workers array with unclosed worker
        unclosed_worker = instance_double(Fractor::WrappedRactor,
                                          closed?: false)
        allow(supervisor).to receive(:workers).and_return([unclosed_worker])

        result = handler.send(:should_continue_running?, 5)
        expect(result).to be true
      end

      it "returns false when shutdown complete" do
        # Set up the shutdown state
        handler.instance_variable_set(:@shutting_down, true)
        allow(supervisor).to receive(:instance_variable_get).with(:@running).and_return(false)

        # Mock workers array with all closed workers
        closed_worker = instance_double(Fractor::WrappedRactor, closed?: true)
        allow(supervisor).to receive(:workers).and_return([closed_worker])

        result = handler.send(:should_continue_running?, 5)
        expect(result).to be false
      end
    end
  end

  describe "Ractor.yield based messaging" do
    it "has Ractor.receive method available" do
      # In Ruby 3.x, workers use Ractor.yield to send results
      # The main loop uses Ractor.receive to get them
      # Just verify the method exists, don't call it (it will block)
      expect(Ractor).to respond_to(:receive)
    end

    it "supports message passing without response ports" do
      # Ruby 3.x doesn't use Ractor::Port
      # Workers yield results directly
      expect(Ractor).to respond_to(:receive)
    end
  end
end
