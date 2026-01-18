# frozen_string_literal: true

require "spec_helper"
require_relative "../../../lib/fractor/workflow/dead_letter_queue"
require_relative "../../../lib/fractor/work"

RSpec.describe Fractor::Workflow::DeadLetterQueue do
  let(:work) { Fractor::Work.new("test data") }
  let(:error) { StandardError.new("Test error") }
  let(:dlq) { described_class.new }

  describe "#initialize" do
    it "initializes with default values" do
      expect(dlq.max_size).to be_nil
      expect(dlq.entries).to be_empty
    end

    it "accepts max_size parameter" do
      dlq_with_max = described_class.new(max_size: 100)
      expect(dlq_with_max.max_size).to eq(100)
    end

    it "accepts persistence parameter" do
      dlq_file = described_class.new(persistence: :file,
                                     file_path: "test_dlq.json")
      expect(dlq_file.instance_variable_get(:@persistence)).to eq(:file)
    end
  end

  describe "#add" do
    it "adds an entry to the queue" do
      entry = dlq.add(work, error)

      expect(entry).to be_a(Fractor::Workflow::DeadLetterQueue::Entry)
      expect(entry.work).to eq(work)
      expect(entry.error).to eq(error)
      expect(dlq.size).to eq(1)
    end

    it "includes context in entry" do
      context = { job_id: "test_job", attempt: 3 }
      entry = dlq.add(work, error, context: context)

      expect(entry.context).to eq(context)
    end

    it "includes metadata in entry" do
      metadata = { correlation_id: "123", user_id: "456" }
      entry = dlq.add(work, error, metadata: metadata)

      expect(entry.metadata).to eq(metadata)
    end

    it "sets timestamp on entry" do
      entry = dlq.add(work, error)
      expect(entry.timestamp).to be_a(Time)
      expect(entry.timestamp).to be <= Time.now
    end

    it "enforces max_size by removing oldest entries" do
      dlq_limited = described_class.new(max_size: 3)

      work1 = Fractor::Work.new("data1")
      work2 = Fractor::Work.new("data2")
      work3 = Fractor::Work.new("data3")
      work4 = Fractor::Work.new("data4")

      dlq_limited.add(work1, error)
      dlq_limited.add(work2, error)
      dlq_limited.add(work3, error)
      dlq_limited.add(work4, error) # This should remove work1

      expect(dlq_limited.size).to eq(3)
      expect(dlq_limited.all.map(&:work)).not_to include(work1)
      expect(dlq_limited.all.map(&:work)).to include(work2, work3, work4)
    end

    it "notifies registered handlers" do
      notifications = []
      dlq.on_add { |entry| notifications << entry }

      entry = dlq.add(work, error)

      expect(notifications.size).to eq(1)
      expect(notifications.first).to eq(entry)
    end

    it "handles handler errors gracefully" do
      dlq.on_add { |_entry| raise "Handler error" }

      expect do
        dlq.add(work, error)
      end.not_to raise_error
    end
  end

  describe "#on_add" do
    it "registers a handler" do
      called = false
      dlq.on_add { |_entry| called = true }

      dlq.add(work, error)

      expect(called).to be true
    end

    it "supports multiple handlers" do
      calls = []
      dlq.on_add { |_entry| calls << 1 }
      dlq.on_add { |_entry| calls << 2 }

      dlq.add(work, error)

      expect(calls).to eq([1, 2])
    end
  end

  describe "#all" do
    it "returns all entries" do
      work1 = Fractor::Work.new("data1")
      work2 = Fractor::Work.new("data2")

      dlq.add(work1, error)
      dlq.add(work2, error)

      entries = dlq.all
      expect(entries.size).to eq(2)
      expect(entries.map(&:work)).to contain_exactly(work1, work2)
    end

    it "returns a copy of entries" do
      dlq.add(work, error)
      entries = dlq.all
      entries.clear

      expect(dlq.size).to eq(1)
    end
  end

  describe "#filter" do
    it "filters entries by condition" do
      work1 = Fractor::Work.new("data1")
      work2 = Fractor::Work.new("data2")
      error1 = StandardError.new("Error 1")
      error2 = ArgumentError.new("Error 2")

      dlq.add(work1, error1)
      dlq.add(work2, error2)

      filtered = dlq.filter { |entry| entry.error.is_a?(ArgumentError) }

      expect(filtered.size).to eq(1)
      expect(filtered.first.work).to eq(work2)
    end
  end

  describe "#by_error_class" do
    it "returns entries for specific error class" do
      work1 = Fractor::Work.new("data1")
      work2 = Fractor::Work.new("data2")
      error1 = StandardError.new("Error 1")
      error2 = ArgumentError.new("Error 2")

      dlq.add(work1, error1)
      dlq.add(work2, error2)

      entries = dlq.by_error_class(ArgumentError)

      expect(entries.size).to eq(1)
      expect(entries.first.work).to eq(work2)
    end
  end

  describe "#by_time_range" do
    it "returns entries within time range" do
      now = Time.now
      past = now - 3600
      future = now + 3600

      # Add entry from the past
      entry1 = dlq.add(work, error)
      entry1.instance_variable_set(:@timestamp, past)

      # Add entry from now
      entry2 = dlq.add(Fractor::Work.new("data2"), error)

      # Query for recent entries only
      entries = dlq.by_time_range(now - 1800, future)

      expect(entries.size).to eq(1)
      expect(entries.first).to eq(entry2)
    end
  end

  describe "#remove" do
    it "removes an entry" do
      entry = dlq.add(work, error)
      expect(dlq.size).to eq(1)

      removed = dlq.remove(entry)

      expect(removed).to eq(entry)
      expect(dlq.size).to eq(0)
    end

    it "returns nil when entry not found" do
      entry = Fractor::Workflow::DeadLetterQueue::Entry.new(
        work: work,
        error: error,
      )

      result = dlq.remove(entry)

      expect(result).to be_nil
    end
  end

  describe "#clear" do
    it "removes all entries" do
      dlq.add(work, error)
      dlq.add(Fractor::Work.new("data2"), error)

      count = dlq.clear

      expect(count).to eq(2)
      expect(dlq.size).to eq(0)
    end
  end

  describe "#size" do
    it "returns current queue size" do
      expect(dlq.size).to eq(0)

      dlq.add(work, error)
      expect(dlq.size).to eq(1)

      dlq.add(Fractor::Work.new("data2"), error)
      expect(dlq.size).to eq(2)
    end
  end

  describe "#empty?" do
    it "returns true when queue is empty" do
      expect(dlq.empty?).to be true
    end

    it "returns false when queue has entries" do
      dlq.add(work, error)
      expect(dlq.empty?).to be false
    end
  end

  describe "#full?" do
    it "returns false when no max_size set" do
      expect(dlq.full?).to be false
    end

    it "returns true when at max_size" do
      dlq_limited = described_class.new(max_size: 2)
      dlq_limited.add(work, error)
      dlq_limited.add(Fractor::Work.new("data2"), error)

      expect(dlq_limited.full?).to be true
    end

    it "returns false when below max_size" do
      dlq_limited = described_class.new(max_size: 5)
      dlq_limited.add(work, error)

      expect(dlq_limited.full?).to be false
    end
  end

  describe "#stats" do
    it "returns queue statistics" do
      entry1 = dlq.add(work, StandardError.new("Error 1"))
      entry2 = dlq.add(Fractor::Work.new("data2"), ArgumentError.new("Error 2"))

      stats = dlq.stats

      expect(stats[:size]).to eq(2)
      expect(stats[:max_size]).to be_nil
      expect(stats[:full]).to be false
      expect(stats[:oldest_timestamp]).to eq(entry1.timestamp)
      expect(stats[:newest_timestamp]).to eq(entry2.timestamp)
      expect(stats[:error_classes]).to contain_exactly("StandardError",
                                                       "ArgumentError")
      expect(stats[:persistence]).to eq(:memory)
    end
  end

  describe "#retry_entry" do
    it "retries an entry and removes on success" do
      entry = dlq.add(work, error)
      success = false

      result = dlq.retry_entry(entry) do |w|
        success = true
        expect(w).to eq(work)
      end

      expect(result).to be true
      expect(success).to be true
      expect(dlq.size).to eq(0)
    end

    it "adds back to queue on retry failure" do
      entry = dlq.add(work, error)

      result = dlq.retry_entry(entry) do |_w|
        raise StandardError, "Retry failed"
      end

      expect(result).to be false
      expect(dlq.size).to eq(1)
      expect(dlq.all.first.metadata[:retried]).to be true
    end

    it "returns false when no block given" do
      entry = dlq.add(work, error)
      result = dlq.retry_entry(entry)

      expect(result).to be false
      expect(dlq.size).to eq(1)
    end
  end

  describe "#retry_all" do
    it "retries all entries" do
      work1 = Fractor::Work.new("data1")
      work2 = Fractor::Work.new("data2")

      dlq.add(work1, error)
      dlq.add(work2, error)

      processed = []
      results = dlq.retry_all { |w| processed << w }

      expect(results[:success]).to eq(2)
      expect(results[:failed]).to eq(0)
      expect(processed).to contain_exactly(work1, work2)
      expect(dlq.size).to eq(0)
    end

    it "counts successes and failures" do
      work1 = Fractor::Work.new("data1")
      work2 = Fractor::Work.new("data2")

      dlq.add(work1, error)
      dlq.add(work2, error)

      results = dlq.retry_all do |w|
        raise "Fail" if w == work2
      end

      expect(results[:success]).to eq(1)
      expect(results[:failed]).to eq(1)
    end
  end

  describe "Entry#to_h" do
    it "converts entry to hash" do
      context = { job_id: "test_job" }
      metadata = { user_id: "123" }
      entry = dlq.add(work, error, context: context, metadata: metadata)

      hash = entry.to_h

      expect(hash[:work]).to eq(work)
      expect(hash[:error]).to eq("Test error")
      expect(hash[:error_class]).to eq("StandardError")
      expect(hash[:context]).to eq(context)
      expect(hash[:timestamp]).to be_a(String)
      expect(hash[:metadata]).to eq(metadata)
    end
  end

  describe "thread safety" do
    it "is thread-safe for concurrent adds" do
      threads = Array.new(10) do |i|
        Thread.new do
          10.times do |j|
            work_item = Fractor::Work.new("data-#{i}-#{j}")
            dlq.add(work_item, error)
          end
        end
      end

      threads.each(&:join)

      expect(dlq.size).to eq(100)
    end
  end
end

RSpec.describe Fractor::Workflow::FilePersister do
  let(:file_path) { "test_dlq_spec.json" }
  let(:persister) { described_class.new(file_path: file_path) }
  let(:work) { Fractor::Work.new("test data") }
  let(:error) { StandardError.new("Test error") }
  let(:entry) do
    Fractor::Workflow::DeadLetterQueue::Entry.new(
      work: work,
      error: error,
    )
  end

  after do
    File.delete(file_path) if File.exist?(file_path)
  end

  describe "#persist" do
    it "persists entry to file" do
      persister.persist(entry)

      expect(File.exist?(file_path)).to be true
      content = JSON.parse(File.read(file_path), symbolize_names: true)
      expect(content).to be_an(Array)
      expect(content.size).to eq(1)
    end

    it "appends to existing entries" do
      entry2 = Fractor::Workflow::DeadLetterQueue::Entry.new(
        work: Fractor::Work.new("data2"),
        error: error,
      )

      persister.persist(entry)
      persister.persist(entry2)

      content = JSON.parse(File.read(file_path), symbolize_names: true)
      expect(content.size).to eq(2)
    end
  end

  describe "#remove" do
    it "removes entry from file" do
      persister.persist(entry)
      persister.remove(entry)

      content = JSON.parse(File.read(file_path), symbolize_names: true)
      expect(content).to be_empty
    end
  end

  describe "#clear" do
    it "deletes the file" do
      persister.persist(entry)
      expect(File.exist?(file_path)).to be true

      persister.clear

      expect(File.exist?(file_path)).to be false
    end
  end
end
