# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"

RSpec.describe Fractor::PersistentWorkQueue do
  let(:temp_dir) { Dir.mktmpdir("fractor_persistent_queue_test") }
  let(:queue_file) { File.join(temp_dir, "queue.json") }

  after do
    # Clean up temp directory
    FileUtils.rm_rf(temp_dir) if Dir.exist?(temp_dir)
  end

  # Simple test work class
  class TestWork < Fractor::Work
    def initialize(value)
      super({ value: value })
    end

    def value
      input[:value]
    end
  end

  describe "#initialize" do
    it "accepts a file path string" do
      queue = described_class.new(queue_file)
      expect(queue.persister).to be_a(Fractor::QueuePersister::JSONPersister)
    end

    it "accepts a custom persister" do
      persister = Fractor::QueuePersister::YAMLPersister.new(File.join(
                                                               temp_dir, "queue.yml"
                                                             ))
      queue = described_class.new(persister)
      expect(queue.persister).to eq(persister)
    end

    it "accepts nil persister for in-memory queue" do
      queue = described_class.new(nil)
      expect(queue.persister).to be_nil
    end

    it "sets auto_save to true by default when persister is provided" do
      queue = described_class.new(queue_file)
      expect(queue.instance_variable_get(:@auto_save)).to be true
    end

    it "allows disabling auto_save" do
      queue = described_class.new(queue_file, auto_save: false)
      expect(queue.instance_variable_get(:@auto_save)).to be false
    end
  end

  describe "#enqueue" do
    it "adds work items to the queue" do
      queue = described_class.new(queue_file, auto_save: false)
      work = TestWork.new(42)

      queue.enqueue(work)

      expect(queue.size).to eq(1)
    end

    it "marks queue as dirty after enqueue" do
      queue = described_class.new(queue_file, auto_save: false)
      work = TestWork.new(42)

      queue.enqueue(work)

      expect(queue.dirty?).to be true
    end

    it "automatically saves when auto_save is enabled" do
      queue = described_class.new(queue_file, auto_save: true)
      work = TestWork.new(42)

      queue.enqueue(work)

      expect(File.exist?(queue_file)).to be true
    end

    it "does not save when auto_save is disabled" do
      queue = described_class.new(queue_file, auto_save: false)
      work = TestWork.new(42)

      queue.enqueue(work)

      expect(File.exist?(queue_file)).to be false
    end
  end

  describe "#<<" do
    it "is an alias for enqueue" do
      queue = described_class.new(queue_file, auto_save: false)
      work = TestWork.new(42)

      queue << work

      expect(queue.size).to eq(1)
    end
  end

  describe "#save" do
    it "saves queue state to disk" do
      queue = described_class.new(queue_file, auto_save: false)
      work1 = TestWork.new(1)
      work2 = TestWork.new(2)

      queue << work1
      queue << work2
      result = queue.save

      expect(result).to be true
      expect(File.exist?(queue_file)).to be true
      expect(queue.dirty?).to be false
    end

    it "returns false when persister is nil" do
      queue = described_class.new(nil, auto_save: false)
      work = TestWork.new(42)

      queue << work
      result = queue.save

      expect(result).to be false
    end
  end

  describe "#load" do
    it "loads work items from disk" do
      # First, save some work
      queue = described_class.new(queue_file, auto_save: false)
      work1 = TestWork.new(1)
      work2 = TestWork.new(2)

      queue << work1
      queue << work2
      queue.save

      # Create new queue and load
      new_queue = described_class.new(queue_file, auto_save: false)
      count = new_queue.load

      expect(count).to eq(2)
      expect(new_queue.size).to eq(2)
      expect(new_queue.dirty?).to be false
    end

    it "returns 0 when persister is nil" do
      queue = described_class.new(nil)
      count = queue.load

      expect(count).to eq(0)
    end

    it "returns 0 when file doesn't exist" do
      queue = described_class.new(queue_file, auto_save: false)
      count = queue.load

      expect(count).to eq(0)
    end

    it "preserves work item data" do
      queue = described_class.new(queue_file, auto_save: false)
      # Use base Work class for predictable serialization
      original_work = Fractor::Work.new({ value: 42 })

      queue << original_work
      queue.save

      # Create new queue and load
      new_queue = described_class.new(queue_file, auto_save: false)
      new_queue.load

      # Pop the work item and verify
      loaded_work = new_queue.pop_batch(1).first
      expect(loaded_work).to be_a(Fractor::Work)
      # JSON converts symbol keys to string keys
      expect(loaded_work.input).to eq({ "value" => 42 })
    end
  end

  describe "#clear" do
    it "clears the queue and removes persisted file" do
      queue = described_class.new(queue_file, auto_save: false)
      work = TestWork.new(42)

      queue << work
      queue.save
      expect(File.exist?(queue_file)).to be true

      queue.clear

      expect(queue.size).to eq(0)
      expect(File.exist?(queue_file)).to be false
      expect(queue.dirty?).to be false
    end

    it "works when persister is nil" do
      queue = described_class.new(nil)
      work = TestWork.new(42)

      queue << work
      result = queue.clear

      expect(result).to be true
      expect(queue.size).to eq(0)
    end
  end

  describe "#close" do
    it "saves dirty queue before closing" do
      queue = described_class.new(queue_file, auto_save: false)
      work = TestWork.new(42)

      queue << work
      expect(queue.dirty?).to be true

      queue.close

      expect(File.exist?(queue_file)).to be true
    end

    it "stops auto-save thread if running" do
      queue = described_class.new(queue_file, auto_save: false,
                                              save_interval: 1)
      work = TestWork.new(42)

      queue << work

      # Close should stop the thread
      queue.close

      # Thread should be stopped
      expect(queue.instance_variable_get(:@save_thread)).to be_nil
    end
  end

  describe "integration with ContinuousServer" do
    it "can be used with ContinuousServer" do
      queue = described_class.new(queue_file)

      # Add some initial work
      3.times { |i| queue << TestWork.new(i) }
      queue.save

      # Server can use the queue
      server = Fractor::ContinuousServer.new(
        worker_pools: [{ worker_class: Class.new(Fractor::Worker) }],
        work_queue: queue,
      )

      expect(server.work_queue).to eq(queue)
    end
  end
end

RSpec.describe Fractor::QueuePersister do
  let(:temp_dir) { Dir.mktmpdir("fractor_persister_test") }

  after do
    FileUtils.rm_rf(temp_dir) if Dir.exist?(temp_dir)
  end

  describe Fractor::QueuePersister::JSONPersister do
    let(:persister) { described_class.new(File.join(temp_dir, "test.json")) }

    it "saves and loads work items" do
      work1 = Fractor::Work.new({ id: 1 }, timeout: 10)
      work2 = Fractor::Work.new({ id: 2 })

      persister.save([work1, work2])
      loaded = persister.load

      expect(loaded).to be_a(Array)
      expect(loaded.size).to eq(2)
      # JSON uses string keys, not symbols
      expect(loaded.first["_class"]).to eq("Fractor::Work")
      expect(loaded.first["_input"]).to eq({ "id" => 1 })
      expect(loaded.first["_timeout"]).to eq(10)
    end

    it "returns nil when file doesn't exist" do
      loaded = persister.load
      expect(loaded).to be_nil
    end

    it "clears the file" do
      persister.save([Fractor::Work.new({ id: 1 })])

      expect(persister.clear).to be true
      expect(File.exist?(persister.instance_variable_get(:@path))).to be false
    end
  end

  describe Fractor::QueuePersister::YAMLPersister do
    let(:persister) { described_class.new(File.join(temp_dir, "test.yml")) }

    it "saves and loads work items" do
      work1 = Fractor::Work.new({ id: 1 })
      work2 = Fractor::Work.new({ id: 2 })

      persister.save([work1, work2])
      loaded = persister.load

      expect(loaded).to be_a(Array)
      expect(loaded.size).to eq(2)
    end
  end

  describe Fractor::QueuePersister::MarshalPersister do
    let(:persister) { described_class.new(File.join(temp_dir, "test.marshal")) }

    it "saves and loads work items" do
      work1 = Fractor::Work.new({ id: 1 })
      work2 = Fractor::Work.new({ id: 2 })

      persister.save([work1, work2])
      loaded = persister.load

      expect(loaded).to be_a(Array)
      expect(loaded.size).to eq(2)
    end
  end
end
