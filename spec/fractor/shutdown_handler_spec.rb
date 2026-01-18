# frozen_string_literal: true

require "spec_helper"

RSpec.describe Fractor::ShutdownHandler do
  let(:workers) { [] }
  let(:wakeup_ractor) { nil }
  let(:timer_thread) { nil }
  let(:performance_monitor) { nil }
  let(:handler) do
    described_class.new(
      workers,
      wakeup_ractor,
      timer_thread,
      performance_monitor,
      debug: false,
    )
  end

  describe "#initialize" do
    it "stores references to provided components" do
      expect(handler.instance_variable_get(:@workers)).to eq(workers)
      expect(handler.instance_variable_get(:@wakeup_ractor)).to eq(wakeup_ractor)
      expect(handler.instance_variable_get(:@timer_thread)).to eq(timer_thread)
      expect(handler.instance_variable_get(:@performance_monitor)).to eq(performance_monitor)
    end

    it "initializes with debug flag" do
      expect(handler.instance_variable_get(:@debug)).to be false
    end
  end

  describe "#shutdown" do
    it "calls stop_performance_monitor" do
      pm = instance_double(Fractor::PerformanceMonitor, stop: true)
      handler = described_class.new(
        workers,
        wakeup_ractor,
        timer_thread,
        pm,
        debug: false,
      )

      expect(pm).to receive(:stop).once
      handler.shutdown
    end

    it "calls stop_timer_thread when thread exists and is alive" do
      thread = Thread.new { sleep }
      handler = described_class.new(
        workers,
        wakeup_ractor,
        thread,
        performance_monitor,
        debug: false,
      )

      expect(thread).to receive(:join).with(1).once
      handler.shutdown
      thread.kill
    end

    it "calls signal_wakeup_ractor when wakeup_ractor exists" do
      ractor = instance_double(Ractor, send: true)
      handler = described_class.new(
        workers,
        ractor,
        timer_thread,
        performance_monitor,
        debug: false,
      )

      expect(ractor).to receive(:send).with(:shutdown).once
      handler.shutdown
    end

    it "calls signal_all_workers" do
      worker = instance_double(Fractor::WrappedRactor,
                               name: "worker-1",
                               send: true,
                               closed?: true)
      handler = described_class.new(
        [worker],
        wakeup_ractor,
        timer_thread,
        performance_monitor,
        debug: false,
      )

      expect(worker).to receive(:send).with(:shutdown).once
      handler.shutdown
    end
  end

  describe "#stop_performance_monitor" do
    context "when performance monitor is enabled" do
      let(:pm) do
        instance_double(Fractor::PerformanceMonitor,
                        stop: true)
      end

      let(:handler) do
        described_class.new(
          workers,
          wakeup_ractor,
          timer_thread,
          pm,
          debug: false,
        )
      end

      it "stops the performance monitor" do
        expect(pm).to receive(:stop).once
        handler.stop_performance_monitor
      end

      it "does not error if performance monitor raises" do
        allow(pm).to receive(:stop).and_raise(StandardError.new("Stop error"))
        expect { handler.stop_performance_monitor }.not_to raise_error
      end
    end

    context "when performance monitor is nil" do
      it "returns early without error" do
        expect { handler.stop_performance_monitor }.not_to raise_error
      end
    end
  end

  describe "#stop_timer_thread" do
    context "when timer thread exists and is alive" do
      let(:thread) do
        Thread.new { sleep 10 }
      end

      let(:handler) do
        described_class.new(
          workers,
          wakeup_ractor,
          thread,
          performance_monitor,
          debug: false,
        )
      end

      it "waits for thread to finish" do
        expect(thread).to receive(:join).with(1).once
        handler.stop_timer_thread
      end

      it "kills the thread after wait" do
        handler.stop_timer_thread
        # Wait a bit for the thread to be killed
        sleep(0.1)
        # Thread should be dead now
        expect(thread.alive?).to be false
      end
    end

    context "when timer thread is nil" do
      it "returns early without error" do
        expect { handler.stop_timer_thread }.not_to raise_error
      end
    end

    context "when timer thread is not alive" do
      let(:thread) do
        t = Thread.new {}
        t.kill
        # Wait for thread to actually die
        sleep(0.01) until !t.alive?
        t
      end

      let(:handler) do
        described_class.new(
          workers,
          wakeup_ractor,
          thread,
          performance_monitor,
          debug: false,
        )
      end

      it "does not call join on dead thread" do
        expect(thread).not_to receive(:join)
        handler.stop_timer_thread
      end
    end
  end

  describe "#signal_wakeup_ractor" do
    context "when wakeup_ractor exists" do
      let(:ractor) do
        instance_double(Ractor, send: true)
      end

      let(:handler) do
        described_class.new(
          workers,
          ractor,
          timer_thread,
          performance_monitor,
          debug: false,
        )
      end

      it "sends shutdown signal to ractor" do
        expect(ractor).to receive(:send).with(:shutdown).once
        handler.signal_wakeup_ractor
      end

      it "does not error if ractor raises error" do
        allow(ractor).to receive(:send).and_raise(StandardError.new("Send error"))
        expect { handler.signal_wakeup_ractor }.not_to raise_error
      end
    end

    context "when wakeup_ractor is nil" do
      it "returns early without error" do
        expect { handler.signal_wakeup_ractor }.not_to raise_error
      end
    end
  end

  describe "#signal_all_workers" do
    context "with multiple workers" do
      let(:worker1) do
        instance_double(Fractor::WrappedRactor,
                        name: "worker-1",
                        send: true,
                        closed?: true)
      end

      let(:worker2) do
        instance_double(Fractor::WrappedRactor,
                        name: "worker-2",
                        send: true,
                        closed?: false)
      end

      let(:handler) do
        described_class.new(
          [worker1, worker2],
          wakeup_ractor,
          timer_thread,
          performance_monitor,
          debug: false,
        )
      end

      it "sends shutdown signal to all workers" do
        expect(worker1).to receive(:send).with(:shutdown).once
        expect(worker2).to receive(:send).with(:shutdown).once
        handler.signal_all_workers
      end

      it "continues if a worker raises error" do
        allow(worker1).to receive(:send).and_raise(StandardError.new("Worker error"))
        expect(worker2).to receive(:send).with(:shutdown).once
        expect { handler.signal_all_workers }.not_to raise_error
      end
    end

    context "with empty workers array" do
      it "does not error" do
        expect { handler.signal_all_workers }.not_to raise_error
      end
    end
  end

  describe "#complete?" do
    context "when all components are stopped" do
      let(:thread) do
        t = Thread.new {}
        t.kill
        # Wait for thread to actually die
        sleep(0.01) until !t.alive?
        t
      end

      let(:worker) do
        instance_double(Fractor::WrappedRactor, closed?: true)
      end

      let(:handler) do
        described_class.new(
          [worker],
          nil,
          thread,
          nil,
          debug: false,
        )
      end

      it "returns true" do
        expect(handler.complete?).to be true
      end
    end

    context "when timer thread is still running" do
      let(:thread) do
        Thread.new { sleep 10 }
      end

      let(:handler) do
        described_class.new(
          [],
          wakeup_ractor,
          thread,
          nil,
          debug: false,
        )
      end

      it "returns false" do
        expect(handler.complete?).to be false
      end
    end

    context "when workers are still open" do
      let(:worker) do
        instance_double(Fractor::WrappedRactor, closed?: false)
      end

      let(:handler) do
        described_class.new(
          [worker],
          wakeup_ractor,
          timer_thread,
          nil,
          debug: false,
        )
      end

      it "returns false" do
        expect(handler.complete?).to be false
      end
    end
  end

  describe "#status_summary" do
    let(:worker) do
      instance_double(Fractor::WrappedRactor, name: "worker-1", closed?: true)
    end

    let(:handler) do
      described_class.new(
        [worker],
        wakeup_ractor,
        timer_thread,
        performance_monitor,
        debug: false,
      )
    end

    it "returns status hash with component states" do
      summary = handler.status_summary

      expect(summary).to be_a(Hash)
      expect(summary.keys).to include(:performance_monitor, :timer_thread, :wakeup_ractor,
                                      :workers_count, :workers_closed)
    end

    it "reports workers_count correctly" do
      summary = handler.status_summary
      expect(summary[:workers_count]).to eq(1)
    end

    it "reports workers_closed correctly" do
      summary = handler.status_summary
      expect(summary[:workers_closed]).to eq(1)
    end

    context "with performance monitor" do
      let(:pm) do
        instance_double(Fractor::PerformanceMonitor, monitoring?: true)
      end

      let(:handler) do
        described_class.new(
          workers,
          wakeup_ractor,
          timer_thread,
          pm,
          debug: false,
        )
      end

      it "reports performance_monitor monitoring status" do
        summary = handler.status_summary
        expect(summary[:performance_monitor]).to be true
      end
    end

    context "with wakeup_ractor" do
      let(:ractor) { double("Ractor") }

      let(:handler) do
        described_class.new(
          workers,
          ractor,
          timer_thread,
          performance_monitor,
          debug: false,
        )
      end

      it "reports wakeup_ractor as present" do
        summary = handler.status_summary
        expect(summary[:wakeup_ractor]).to be true
      end
    end
  end
end
