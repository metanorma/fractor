# frozen_string_literal: true

require "spec_helper"

RSpec.describe Fractor::WorkDistributionManager do
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

  let(:work_queue) { Queue.new }
  let(:workers) { [] }
  let(:ractors_map) { {} }
  let(:manager) do
    described_class.new(
      work_queue,
      workers,
      ractors_map,
      debug: false,
      continuous_mode: false
    )
  end

  describe "#initialize" do
    it "initializes with empty idle workers" do
      expect(manager.idle_workers).to be_empty
    end

    it "stores references to provided objects" do
      expect(manager.instance_variable_get(:@work_queue)).to eq(work_queue)
      expect(manager.instance_variable_get(:@workers)).to eq(workers)
      expect(manager.instance_variable_get(:@ractors_map)).to eq(ractors_map)
    end

    it "initializes with empty work start times" do
      expect(manager.instance_variable_get(:@work_start_times)).to be_empty
    end
  end

  describe "#assign_work_to_worker" do
    let(:wrapped_ractor) do
      instance_double("Fractor::WrappedRactor",
                      name: "test-worker",
                      closed?: false,
                      send: true)
    end

    context "when work queue is empty" do
      it "returns false" do
        result = manager.assign_work_to_worker(wrapped_ractor)
        expect(result).to be false
      end

      it "does not send work to the ractor" do
        manager.assign_work_to_worker(wrapped_ractor)
        expect(wrapped_ractor).not_to have_received(:send)
      end
    end

    context "when work queue has items" do
      before do
        work_queue.push(work_class.new(42))
      end

      it "returns true if work was sent" do
        result = manager.assign_work_to_worker(wrapped_ractor)
        expect(result).to be true
      end

      it "sends work to the ractor" do
        manager.assign_work_to_worker(wrapped_ractor)
        expect(wrapped_ractor).to have_received(:send).once
      end

      it "removes work from queue" do
        expect { manager.assign_work_to_worker(wrapped_ractor) }
          .to change { work_queue.size }.from(1).to(0)
      end

      it "removes worker from idle list if present" do
        manager.mark_worker_idle(wrapped_ractor)
        expect { manager.assign_work_to_worker(wrapped_ractor) }
          .to change { manager.idle_count }.from(1).to(0)
      end
    end

    context "when ractor is closed" do
      let(:wrapped_ractor) do
        instance_double("Fractor::WrappedRactor",
                        name: "closed-worker",
                        closed?: true,
                        ractor: Ractor.current)
      end

      before do
        work_queue.push(work_class.new(42))
        ractors_map[Ractor.current] = wrapped_ractor
      end

      it "returns false" do
        result = manager.assign_work_to_worker(wrapped_ractor)
        expect(result).to be false
      end

      it "removes ractor from map" do
        manager.assign_work_to_worker(wrapped_ractor)
        expect(ractors_map.key?(Ractor.current)).to be false
      end
    end

    context "when ractor is nil" do
      it "returns false" do
        result = manager.assign_work_to_worker(nil)
        expect(result).to be false
      end
    end
  end

  describe "#mark_worker_idle" do
    let(:worker) { double("worker", name: "worker-1") }

    it "adds worker to idle list" do
      expect { manager.mark_worker_idle(worker) }
        .to change { manager.idle_count }.from(0).to(1)
    end

    it "does not add duplicate workers" do
      manager.mark_worker_idle(worker)
      expect { manager.mark_worker_idle(worker) }
        .not_to(change { manager.idle_count })
    end

    it "includes worker in idle_workers_list" do
      manager.mark_worker_idle(worker)
      expect(manager.idle_workers_list).to include(worker)
    end
  end

  describe "#mark_worker_busy" do
    let(:worker) { double("worker", name: "worker-1") }

    it "removes worker from idle list" do
      manager.mark_worker_idle(worker)
      expect { manager.mark_worker_busy(worker) }
        .to change { manager.idle_count }.from(1).to(0)
    end

    it "does not error if worker not in idle list" do
      expect { manager.mark_worker_busy(worker) }.not_to raise_error
    end
  end

  describe "#distribute_to_idle_workers" do
    let(:workers) do
      3.times.map do |i|
        instance_double("Fractor::WrappedRactor",
                        name: "worker-#{i}",
                        closed?: false,
                        send: true)
      end
    end

    let(:manager) do
      described_class.new(
        work_queue,
        workers,
        ractors_map,
        debug: false,
        continuous_mode: false
      )
    end

    before do
      workers.each { |w| manager.mark_worker_idle(w) }
    end

    context "when queue has fewer items than idle workers" do
      before do
        2.times { |i| work_queue.push(work_class.new(i)) }
      end

      it "distributes all work items" do
        distributed = manager.distribute_to_idle_workers
        expect(distributed).to eq(2)
      end

      it "leaves one worker idle" do
        manager.distribute_to_idle_workers
        expect(manager.idle_count).to eq(1)
      end

      it "empties the queue" do
        manager.distribute_to_idle_workers
        expect(work_queue).to be_empty
      end
    end

    context "when queue has more items than idle workers" do
      before do
        5.times { |i| work_queue.push(work_class.new(i)) }
      end

      it "distributes to all idle workers" do
        distributed = manager.distribute_to_idle_workers
        expect(distributed).to eq(3)
      end

      it "leaves work items in queue" do
        manager.distribute_to_idle_workers
        expect(work_queue.size).to eq(2)
      end

      it "leaves no idle workers" do
        manager.distribute_to_idle_workers
        expect(manager.idle_count).to eq(0)
      end
    end

    context "when queue is empty" do
      it "returns 0" do
        expect(manager.distribute_to_idle_workers).to eq(0)
      end

      it "does not send work to any workers" do
        manager.distribute_to_idle_workers
        workers.each do |worker|
          expect(worker).not_to have_received(:send)
        end
      end
    end

    context "when no idle workers" do
      before do
        manager.instance_variable_get(:@idle_workers).clear
      end

      it "returns 0" do
        work_queue.push(work_class.new(42))
        expect(manager.distribute_to_idle_workers).to eq(0)
      end

      it "leaves work in queue" do
        work_queue.push(work_class.new(42))
        manager.distribute_to_idle_workers
        expect(work_queue.size).to eq(1)
      end
    end
  end

  describe "#idle_workers_list" do
    let(:worker1) { double("worker-1") }
    let(:worker2) { double("worker-2") }

    it "returns list of idle workers" do
      manager.mark_worker_idle(worker1)
      manager.mark_worker_idle(worker2)
      expect(manager.idle_workers_list).to contain_exactly(worker1, worker2)
    end

    it "returns empty list when no idle workers" do
      expect(manager.idle_workers_list).to be_empty
    end

    it "returns a copy, not the original array" do
      manager.mark_worker_idle(worker1)
      list = manager.idle_workers_list
      list.clear
      expect(manager.idle_count).to eq(1)
    end
  end

  describe "#busy_workers_list" do
    let(:worker1) { double("worker-1") }
    let(:worker2) { double("worker-2") }

    before do
      workers << worker1 << worker2
    end

    it "returns list of busy workers when none are idle" do
      expect(manager.busy_workers_list).to contain_exactly(worker1, worker2)
    end

    it "excludes idle workers" do
      manager.mark_worker_idle(worker1)
      expect(manager.busy_workers_list).to contain_exactly(worker2)
    end

    it "returns empty list when all are idle" do
      manager.mark_worker_idle(worker1)
      manager.mark_worker_idle(worker2)
      expect(manager.busy_workers_list).to be_empty
    end
  end

  describe "#idle_count" do
    it "returns number of idle workers" do
      worker1 = double("worker-1")
      worker2 = double("worker-2")
      manager.mark_worker_idle(worker1)
      manager.mark_worker_idle(worker2)
      expect(manager.idle_count).to eq(2)
    end

    it "returns 0 when no idle workers" do
      expect(manager.idle_count).to eq(0)
    end
  end

  describe "#busy_count" do
    let(:worker1) { double("worker-1") }
    let(:worker2) { double("worker-2") }

    before do
      workers << worker1 << worker2
    end

    it "returns number of busy workers" do
      expect(manager.busy_count).to eq(2)
    end

    it "excludes idle workers from count" do
      manager.mark_worker_idle(worker1)
      expect(manager.busy_count).to eq(1)
    end

    it "returns 0 when all are idle" do
      manager.mark_worker_idle(worker1)
      manager.mark_worker_idle(worker2)
      expect(manager.busy_count).to eq(0)
    end
  end

  describe "#get_work_start_time" do
    let(:work) { work_class.new(42) }

    context "when performance monitor is enabled" do
      let(:performance_monitor) { instance_double("Fractor::PerformanceMonitor") }

      let(:manager) do
        described_class.new(
          work_queue,
          workers,
          ractors_map,
          debug: false,
          continuous_mode: false,
          performance_monitor: performance_monitor
        )
      end

      before do
        work_queue.push(work)
        # Simulate tracking start time by directly setting it
        manager.instance_variable_get(:@work_start_times)[work.object_id] = Time.now
      end

      it "returns the start time" do
        start_time = manager.get_work_start_time(work.object_id)
        expect(start_time).to be_a(Time)
      end

      it "removes the start time from tracking" do
        expect { manager.get_work_start_time(work.object_id) }
          .to change { manager.instance_variable_get(:@work_start_times).size }.from(1).to(0)
      end
    end

    context "when performance monitor is disabled" do
      it "returns nil" do
        work = work_class.new(42)
        expect(manager.get_work_start_time(work.object_id)).to be_nil
      end
    end
  end

  describe "#clear_work_start_times" do
    let(:performance_monitor) { instance_double("Fractor::PerformanceMonitor") }

    let(:manager) do
      described_class.new(
        work_queue,
        workers,
        ractors_map,
        debug: false,
        continuous_mode: false,
        performance_monitor: performance_monitor
      )
    end

    it "clears all tracked start times" do
      work1 = work_class.new(1)
      work2 = work_class.new(2)
      manager.instance_variable_get(:@work_start_times)[work1.object_id] = Time.now
      manager.instance_variable_get(:@work_start_times)[work2.object_id] = Time.now

      expect { manager.clear_work_start_times }
        .to change { manager.instance_variable_get(:@work_start_times).size }.from(2).to(0)
    end
  end

  describe "#status_summary" do
    let(:worker1) { double("worker-1") }
    let(:worker2) { double("worker-2") }

    before do
      workers << worker1 << worker2
    end

    it "returns status hash with idle and busy counts" do
      summary = manager.status_summary
      expect(summary).to eq({ idle: 0, busy: 2 })
    end

    it "counts idle workers correctly" do
      manager.mark_worker_idle(worker1)
      summary = manager.status_summary
      expect(summary[:idle]).to eq(1)
      expect(summary[:busy]).to eq(1)
    end

    it "counts all workers as idle when marked as such" do
      manager.mark_worker_idle(worker1)
      manager.mark_worker_idle(worker2)
      summary = manager.status_summary
      expect(summary).to eq({ idle: 2, busy: 0 })
    end
  end
end
