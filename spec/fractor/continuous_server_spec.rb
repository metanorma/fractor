# frozen_string_literal: true

require "spec_helper"
require "tempfile"

RSpec.describe Fractor::ContinuousServer do
  let(:worker_class) do
    Class.new(Fractor::Worker) do
      def process(work)
        { processed: work.input }
      end
    end
  end

  let(:worker_pools) do
    [{ worker_class: worker_class, num_workers: 2 }]
  end

  let(:work_queue) { Fractor::WorkQueue.new }

  describe "#initialize" do
    it "creates a server with worker pools" do
      server = described_class.new(worker_pools: worker_pools)
      expect(server).to be_a(described_class)
    end

    it "accepts optional work queue" do
      server = described_class.new(
        worker_pools: worker_pools,
        work_queue: work_queue,
      )
      expect(server.work_queue).to eq(work_queue)
    end

    it "accepts optional log file path" do
      server = described_class.new(
        worker_pools: worker_pools,
        log_file: "logs/test.log",
      )
      expect(server).to be_a(described_class)
    end
  end

  describe "#on_result" do
    it "registers a result callback" do
      server = described_class.new(worker_pools: worker_pools)
      callback_called = false

      server.on_result { |_result| callback_called = true }

      expect(callback_called).to be false
    end

    it "allows multiple result callbacks" do
      server = described_class.new(worker_pools: worker_pools)
      callbacks_called = []

      server.on_result { |_result| callbacks_called << :first }
      server.on_result { |_result| callbacks_called << :second }

      expect(callbacks_called).to eq([])
    end
  end

  describe "#on_error" do
    it "registers an error callback" do
      server = described_class.new(worker_pools: worker_pools)
      callback_called = false

      server.on_error { |_error| callback_called = true }

      expect(callback_called).to be false
    end

    it "allows multiple error callbacks" do
      server = described_class.new(worker_pools: worker_pools)
      callbacks_called = []

      server.on_error { |_error| callbacks_called << :first }
      server.on_error { |_error| callbacks_called << :second }

      expect(callbacks_called).to eq([])
    end
  end

  describe "#run and #stop" do
    it "starts supervisor and processes work items" do
      server = described_class.new(
        worker_pools: worker_pools,
        work_queue: work_queue,
      )

      results = []
      server.on_result { |result| results << result }

      server_thread = Thread.new { server.run }

      sleep(0.2)

      5.times { |i| work_queue << Fractor::Work.new("data_#{i}") }

      sleep(0.5)

      server.stop
      server_thread.join(2)

      expect(results.size).to be > 0
      expect(results.first.success?).to be true
    end

    it "handles errors from workers" do
      error_worker = Class.new(Fractor::Worker) do
        def process(_work)
          raise "Test error"
        end
      end

      server = described_class.new(
        worker_pools: [{ worker_class: error_worker, num_workers: 1 }],
        work_queue: work_queue,
      )

      errors = []
      server.on_error { |error| errors << error }

      server_thread = Thread.new { server.run }

      sleep(0.2)

      work_queue << Fractor::Work.new("test_data")

      sleep(0.5)

      server.stop
      server_thread.join(2)

      expect(errors.size).to be > 0
      expect(errors.first.error).to match(/Test error/)
    end

    it "stops cleanly when requested" do
      server = described_class.new(
        worker_pools: worker_pools,
        work_queue: work_queue,
      )

      server_thread = Thread.new { server.run }

      sleep(0.2)

      server.stop

      expect(server_thread.join(2)).to eq(server_thread)
    end

    it "processes callbacks in order" do
      server = described_class.new(
        worker_pools: worker_pools,
        work_queue: work_queue,
      )

      call_order = []
      server.on_result { |_result| call_order << :first }
      server.on_result { |_result| call_order << :second }

      server_thread = Thread.new { server.run }

      sleep(0.2)

      work_queue << Fractor::Work.new("test_data")

      sleep(0.5)

      server.stop
      server_thread.join(2)

      expect(call_order).to eq(%i[first second])
    end
  end

  describe "log file handling" do
    it "creates log directory if needed" do
      log_path = "tmp/test_logs/server.log"
      FileUtils.rm_rf("tmp/test_logs")

      server = described_class.new(
        worker_pools: worker_pools,
        log_file: log_path,
      )

      server_thread = Thread.new { server.run }

      sleep(0.2)

      server.stop
      server_thread.join(2)

      expect(File.exist?(log_path)).to be true

      FileUtils.rm_rf("tmp/test_logs")
    end

    it "writes log messages to file" do
      log_file = Tempfile.new(["test_log", ".log"])
      log_path = log_file.path
      log_file.close

      server = described_class.new(
        worker_pools: worker_pools,
        log_file: log_path,
      )

      server_thread = Thread.new { server.run }

      sleep(0.2)

      server.stop
      server_thread.join(2)

      log_contents = File.read(log_path)
      expect(log_contents).to include("Continuous server started")

      File.delete(log_path) if File.exist?(log_path)
    end

    it "closes log file on cleanup" do
      log_file = Tempfile.new(["test_log", ".log"])
      log_path = log_file.path
      log_file.close

      server = described_class.new(
        worker_pools: worker_pools,
        log_file: log_path,
      )

      server_thread = Thread.new { server.run }

      sleep(0.2)

      server.stop
      server_thread.join(2)

      log_file_handle = server.instance_variable_get(:@log_file)
      expect(log_file_handle).to be_nil

      File.delete(log_path) if File.exist?(log_path)
    end
  end

  describe "integration with WorkQueue" do
    it "auto-registers work queue with supervisor" do
      server = described_class.new(
        worker_pools: worker_pools,
        work_queue: work_queue,
      )

      results = []
      server.on_result { |result| results << result }

      server_thread = Thread.new { server.run }

      sleep(0.2)

      3.times { |i| work_queue << Fractor::Work.new("data_#{i}") }

      sleep(0.5)

      server.stop
      server_thread.join(2)

      expect(results.size).to eq(3)
    end

    it "works without a work queue" do
      server = described_class.new(worker_pools: worker_pools)

      results = []
      server.on_result { |result| results << result }

      server_thread = Thread.new { server.run }

      sleep(0.2)

      server.supervisor.register_work_source do
        [Fractor::Work.new("manual_data")]
      end

      sleep(0.5)

      server.stop
      server_thread.join(2)

      expect(server.supervisor).to be_a(Fractor::Supervisor)
    end
  end

  describe "error handling in callbacks" do
    it "continues processing even if callback raises error" do
      server = described_class.new(
        worker_pools: worker_pools,
        work_queue: work_queue,
      )

      results = []
      server.on_result do |_result|
        raise "Callback error"
      end
      server.on_result { |result| results << result }

      server_thread = Thread.new { server.run }

      sleep(0.2)

      work_queue << Fractor::Work.new("test_data")

      sleep(0.5)

      server.stop
      server_thread.join(2)

      expect(results.size).to eq(1)
    end
  end
end
