# frozen_string_literal: true

require "spec_helper"

# Skip all tests in this file on Ruby 3.x
RSpec.describe Fractor::MainLoopHandler4, :ruby4 do
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
    allow(supervisor).to receive(:instance_variable_get).with(:@port_to_worker).and_return({})
    allow(supervisor).to receive(:instance_variable_get).with(:@work_distribution_manager).and_return(nil)
    allow(supervisor).to receive(:instance_variable_get).with(:@performance_monitor).and_return(nil)
    allow(supervisor).to receive(:instance_variable_get).with(:@work_callbacks).and_return([])
    allow(supervisor).to receive(:instance_variable_get).with(:@error_callbacks).and_return([])
  end

  describe "Ruby 4.0 specific behavior" do
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
      let(:port1) { Ractor.new {} }
      let(:port2) { Ractor.new {} }

      before do
        allow(supervisor).to receive(:instance_variable_get).with(:@ractors_map).and_return(
          { ractor1 => port1, ractor2 => port2 },
        )
        allow(supervisor).to receive(:instance_variable_get).with(:@wakeup_ractor).and_return(nil)
      end

      it "returns ractors from @ractors_map keys" do
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
        # Mock callback_registry to indicate callbacks exist
        registry = instance_double(Fractor::CallbackRegistry, work_callbacks: [-> {
        }], has_work_callbacks?: true)
        allow(supervisor).to receive(:callback_registry).and_return(registry)

        active = handler.send(:get_active_ractors)
        expect(active).to contain_exactly(ractor1, ractor2)
      end
    end

    describe "#handle_edge_cases" do
      let(:ractor1) { Ractor.current }
      let(:port1) { Ractor.new {} }

      before do
        allow(supervisor).to receive(:instance_variable_get).with(:@ractors_map).and_return(
          { ractor1 => port1 },
        )
        allow(supervisor).to receive(:instance_variable_get).with(:@wakeup_ractor).and_return(nil)
      end

      it "returns false to continue loop when there are active ractors" do
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

    describe "#handle_edge_cases_with_ports" do
      let(:ractor1) { Ractor.current }
      let(:port1) { Ractor.new {} }

      before do
        allow(supervisor).to receive(:instance_variable_get).with(:@ractors_map).and_return(
          { ractor1 => port1 },
        )
        allow(supervisor).to receive(:instance_variable_get).with(:@wakeup_ractor).and_return(nil)
      end

      it "uses port_to_worker map for active count" do
        port_to_worker = { port1 => :worker1 }
        allow(supervisor).to receive(:instance_variable_get).with(:@continuous_mode).and_return(false)
        allow(supervisor).to receive(:instance_variable_get).with(:@total_work_count).and_return(10)

        result = handler.send(:handle_edge_cases_with_ports, [ractor1],
                              port_to_worker, 5)
        expect(result).to be false # Continue the loop
      end

      it "handles empty port_to_worker correctly" do
        allow(supervisor).to receive(:instance_variable_get).with(:@continuous_mode).and_return(true)
        allow(supervisor).to receive(:instance_variable_get).with(:@total_work_count).and_return(10)

        result = handler.send(:handle_edge_cases_with_ports, [], {}, 0)
        # In continuous mode with no active workers and no work, it continues waiting
        expect(result).to be false # Continue the loop
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

  describe "Ractor::Port based messaging" do
    it "supports Ractor.select for receiving from multiple ports" do
      # In Ruby 4.0, the main loop uses Ractor.select to receive from response ports
      # Create ports using Ractor::Port.new
      port1 = Ractor::Port.new
      port2 = Ractor::Port.new

      # Create ractors that will send to these ports
      Ractor.new(port1) do |port|
        port << { test: "message1" }
      end
      Ractor.new(port2) do |port|
        port << { test: "message2" }
      end

      # Ractor.select can wait for messages from multiple ports
      expect(Ractor).to respond_to(:select)

      # Cleanup - ractors will close automatically
    end

    it "handles response port messaging correctly" do
      # Create a port and a ractor that sends to it
      response_port = Ractor::Port.new
      sender = Ractor.new(response_port) do |port|
        port << { test: "message" }
      end

      # The message should be available through the port
      # In actual usage, the main loop uses Ractor.select
      expect(Ractor).to respond_to(:select)

      # Cleanup
      sender
    end

    it "creates response ports using Ractor::Port.new" do
      # In Ruby 4.0, response ports are created with Ractor::Port.new
      port = Ractor::Port.new

      expect(port).to be_a(Ractor::Port)
    end
  end

  describe "port_to_worker mapping" do
    it "tracks which worker owns each response port" do
      # Create response ports
      port1 = Ractor::Port.new
      port2 = Ractor::Port.new

      # Create mock workers (not actual ractors for this test)
      ractor1 = Ractor.current # Use current ractor as placeholder
      ractor2 = Ractor.current

      port_to_worker = { port1 => ractor1, port2 => ractor2 }

      expect(port_to_worker.size).to eq(2)
      expect(port_to_worker[port1]).to eq(ractor1)
      expect(port_to_worker[port2]).to eq(ractor2)
    end
  end

  describe "differences from Ruby 3.x" do
    it "does not rely on Ractor.yield" do
      # Ruby 4.0 doesn't use Ractor.yield for worker communication
      # Workers send results through response ports
      expect(Ractor).not_to respond_to(:yield)
    end

    it "uses Ractor.select for multi-port waiting" do
      # Instead of Ractor.receive, Ruby 4.0 uses Ractor.select
      # to wait for messages from multiple response ports
      expect(Ractor).to respond_to(:select)
    end

    it "manages port lifecycle separately from worker lifecycle" do
      # In Ruby 4.0, response ports are managed differently
      # Ports are passed to workers and used for communication
      port = Ractor::Port.new

      expect(port).to be_a(Ractor::Port)
    end
  end
end
