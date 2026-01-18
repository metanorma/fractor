# frozen_string_literal: true

require "spec_helper"

RSpec.describe Fractor::MainLoopHandler do
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
    instance_double("Fractor::Supervisor",
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

  describe "#initialize" do
    it "stores reference to supervisor" do
      expect(handler.instance_variable_get(:@supervisor)).to eq(supervisor)
    end

    it "stores debug flag" do
      expect(handler.instance_variable_get(:@debug)).to be false
    end
  end

  describe "#get_processed_count" do
    it "returns sum of results and errors" do
      allow(supervisor).to receive(:results).and_return(
        instance_double("ResultAggregator", results: [1, 2], errors: [:error])
      )

      count = handler.send(:get_processed_count)
      expect(count).to eq(3)
    end

    it "returns 0 when no results" do
      allow(supervisor).to receive(:results).and_return(
        instance_double("ResultAggregator", results: [], errors: [])
      )

      expect(handler.send(:get_processed_count)).to eq(0)
    end
  end

  describe "#should_continue_running?" do
    context "when running and in continuous mode" do
      before do
        allow(supervisor).to receive(:instance_variable_get).with(:@running).and_return(true)
        allow(supervisor).to receive(:instance_variable_get).with(:@continuous_mode).and_return(true)
      end

      it "returns true" do
        expect(handler.send(:should_continue_running?, 5)).to be true
      end
    end

    context "when not running" do
      before do
        allow(supervisor).to receive(:instance_variable_get).with(:@running).and_return(false)
      end

      it "returns false" do
        expect(handler.send(:should_continue_running?, 5)).to be false
      end
    end

    context "when in batch mode and work is complete" do
      before do
        allow(supervisor).to receive(:instance_variable_get).with(:@running).and_return(true)
        allow(supervisor).to receive(:instance_variable_get).with(:@continuous_mode).and_return(false)
        allow(supervisor).to receive(:instance_variable_get).with(:@total_work_count).and_return(10)
      end

      it "returns false when processed count equals total" do
        expect(handler.send(:should_continue_running?, 10)).to be false
      end

      it "returns true when processed count is less than total" do
        expect(handler.send(:should_continue_running?, 5)).to be true
      end
    end
  end

  describe "#get_active_ractors" do
    let(:ractor1) { Ractor.current }
    let(:ractor2) { Ractor.new { 1 } }

    before do
      allow(supervisor).to receive(:instance_variable_get).with(:@ractors_map).and_return(
        { ractor1 => :worker1, ractor2 => :worker2 }
      )
      allow(supervisor).to receive(:instance_variable_get).with(:@wakeup_ractor).and_return(nil)
    end

    it "returns all ractors when no wakeup ractor" do
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
      allow(supervisor).to receive(:instance_variable_get).with(:@work_callbacks).and_return([-> {}])

      active = handler.send(:get_active_ractors)
      expect(active).to contain_exactly(ractor1, ractor2)
    end
  end

  describe "#handle_edge_cases" do
    let(:work_distribution_manager) do
      instance_double("Fractor::WorkDistributionManager")
    end

    before do
      allow(supervisor).to receive(:instance_variable_get).with(:@work_distribution_manager)
        .and_return(work_distribution_manager)
      allow(supervisor).to receive(:work_queue).and_return(Queue.new)
    end

    context "when no active workers and queue empty with work remaining" do
      before do
        allow(supervisor).to receive(:instance_variable_get).with(:@continuous_mode).and_return(false)
        allow(supervisor).to receive(:instance_variable_get).with(:@total_work_count).and_return(10)
        allow(supervisor).to receive(:results).and_return(
          instance_double("ResultAggregator", results: [], errors: [])
        )
      end

      it "returns true to break from loop" do
        result = handler.send(:handle_edge_cases, [], 0)
        expect(result).to be true
      end
    end

    context "when in continuous mode with no active ractors" do
      before do
        allow(supervisor).to receive(:instance_variable_get).with(:@continuous_mode).and_return(true)
      end

      it "sleeps and returns false to continue" do
        expect(handler).to receive(:sleep).with(0.1)
        result = handler.send(:handle_edge_cases, [], 0)
        expect(result).to be false
      end
    end

    context "when there are active ractors" do
      it "returns false to continue loop" do
        allow(supervisor).to receive(:instance_variable_get).with(:@continuous_mode).and_return(false)
        ractor = Ractor.current
        result = handler.send(:handle_edge_cases, [ractor], 0)
        expect(result).to be false
      end
    end
  end

  describe "#process_message" do
    let(:wrapped_ractor) do
      instance_double("Fractor::WrappedRactor",
                      name: "test-worker",
                      worker_class: worker_class)
    end

    let(:ractor) { Ractor.current }
    let(:ractors_map) { { ractor => wrapped_ractor } }

    before do
      allow(supervisor).to receive(:instance_variable_get).with(:@ractors_map).and_return(ractors_map)
      allow(supervisor).to receive(:workers).and_return([wrapped_ractor])
      allow(supervisor).to receive(:instance_variable_get).with(:@work_distribution_manager).and_return(
        instance_double("Fractor::WorkDistributionManager")
      )
      allow(supervisor).to receive(:results).and_return(Fractor::ResultAggregator.new)
      allow(supervisor).to receive(:error_reporter).and_return(Fractor::ErrorReporter.new)
      # Allow calling private methods
      allow(supervisor).to receive(:send)
    end

    context "when message is nil (closed ractor)" do
      it "removes ractor from map" do
        handler.send(:process_message, ractor, nil)
        expect(ractors_map).to be_empty
      end

      it "removes worker from workers array" do
        allow(supervisor).to receive(:workers).and_return([])
        handler.send(:process_message, ractor, nil)
      end
    end

    context "when message type is :initialize" do
      let(:message) { { type: :initialize, processor: worker_class } }

      it "assigns work to worker" do
        wdm = instance_double("Fractor::WorkDistributionManager")
        allow(supervisor).to receive(:instance_variable_get).with(:@work_distribution_manager).and_return(wdm)
        expect(wdm).to receive(:assign_work_to_worker).with(wrapped_ractor).and_return(true)

        handler.send(:process_message, ractor, message)
      end
    end

    context "when message type is :shutdown" do
      let(:message) { { type: :shutdown } }

      it "removes ractor from map" do
        handler.send(:process_message, ractor, message)
        expect(ractors_map).to be_empty
      end
    end

    context "when message type is unknown" do
      let(:message) { { type: :unknown } }

      it "does not raise error" do
        expect { handler.send(:process_message, ractor, message) }.not_to raise_error
      end
    end
  end

  describe "#handle_result_message" do
    let(:wrapped_ractor) do
      instance_double("Fractor::WrappedRactor",
                      name: "test-worker",
                      worker_class: worker_class)
    end

    let(:work) { work_class.new(5) }
    let(:work_result) { Fractor::WorkResult.new(result: 10, work: work) }
    let(:message) { { type: :result, result: work_result, processor: worker_class } }
    let(:work_distribution_manager) { instance_double("Fractor::WorkDistributionManager") }

    before do
      allow(supervisor).to receive(:results).and_return(Fractor::ResultAggregator.new)
      allow(supervisor).to receive(:error_reporter).and_return(Fractor::ErrorReporter.new)
      allow(supervisor).to receive(:instance_variable_get).with(:@performance_monitor).and_return(nil)
      allow(supervisor).to receive(:instance_variable_get).with(:@work_distribution_manager).and_return(work_distribution_manager)
      allow(supervisor).to receive(:instance_variable_get).with(:@continuous_mode).and_return(false)
      allow(supervisor).to receive(:instance_variable_get).with(:@total_work_count).and_return(1)
      # Allow calling private methods and stub work distribution
      allow(supervisor).to receive(:send)
      allow(work_distribution_manager).to receive(:assign_work_to_worker).and_return(true)
    end

    it "adds result to results aggregator" do
      handler.send(:handle_result_message, wrapped_ractor, message)
      expect(supervisor.results.results).to contain_exactly(work_result)
    end

    it "records error to error reporter" do
      expect(supervisor.error_reporter).to receive(:record).with(work_result, job_name: worker_class.name)
      handler.send(:handle_result_message, wrapped_ractor, message)
    end
  end

  describe "#handle_error_message" do
    let(:wrapped_ractor) do
      instance_double("Fractor::WrappedRactor",
                      name: "test-worker",
                      worker_class: worker_class)
    end

    let(:work) { work_class.new(5) }
    let(:error_result) { Fractor::WorkResult.new(error: StandardError.new("Test error"), work: work) }
    let(:message) { { type: :error, result: error_result } }
    let(:work_distribution_manager) { instance_double("Fractor::WorkDistributionManager") }

    before do
      allow(supervisor).to receive(:results).and_return(Fractor::ResultAggregator.new)
      allow(supervisor).to receive(:error_reporter).and_return(Fractor::ErrorReporter.new)
      allow(supervisor).to receive(:instance_variable_get).with(:@performance_monitor).and_return(nil)
      allow(supervisor).to receive(:instance_variable_get).with(:@work_distribution_manager).and_return(work_distribution_manager)
      allow(supervisor).to receive(:instance_variable_get).with(:@error_callbacks).and_return([])
      allow(supervisor).to receive(:instance_variable_get).with(:@continuous_mode).and_return(false)
      allow(supervisor).to receive(:instance_variable_get).with(:@total_work_count).and_return(1)
      # Allow calling private methods and stub work distribution
      allow(supervisor).to receive(:send)
      allow(work_distribution_manager).to receive(:assign_work_to_worker).and_return(true)
    end

    it "adds error result to results aggregator" do
      handler.send(:handle_error_message, wrapped_ractor, message)
      expect(supervisor.results.errors).to contain_exactly(error_result)
    end

    it "records error to error reporter" do
      expect(supervisor.error_reporter).to receive(:record).with(error_result, job_name: worker_class.name)
      handler.send(:handle_error_message, wrapped_ractor, message)
    end
  end

  describe "#assign_next_work_or_shutdown" do
    let(:wrapped_ractor) do
      instance_double("Fractor::WrappedRactor",
                      name: "test-worker",
                      worker_class: worker_class)
    end

    let(:work_distribution_manager) { instance_double("Fractor::WorkDistributionManager") }

    before do
      allow(supervisor).to receive(:instance_variable_get).with(:@work_distribution_manager)
        .and_return(work_distribution_manager)
      allow(supervisor).to receive(:results).and_return(Fractor::ResultAggregator.new)
    end

    context "when work is assigned successfully" do
      it "returns early" do
        expect(work_distribution_manager).to receive(:assign_work_to_worker)
          .with(wrapped_ractor)
          .and_return(true)
        expect(work_distribution_manager).not_to receive(:mark_worker_idle)

        handler.send(:assign_next_work_or_shutdown, wrapped_ractor)
      end
    end

    context "when in continuous mode and no work available" do
      before do
        allow(supervisor).to receive(:instance_variable_get).with(:@continuous_mode).and_return(true)
      end

      it "marks worker as idle" do
        expect(work_distribution_manager).to receive(:assign_work_to_worker)
          .with(wrapped_ractor)
          .and_return(false)
        expect(work_distribution_manager).to receive(:mark_worker_idle)
          .with(wrapped_ractor)

        handler.send(:assign_next_work_or_shutdown, wrapped_ractor)
      end
    end
  end
end
