# frozen_string_literal: true

require_relative "../../examples/hierarchical_hasher/hierarchical_hasher"
require "tempfile"

RSpec.describe HierarchicalHasher do
  describe HierarchicalHasher::ChunkWork do
    it "stores chunk data and position" do
      data = "test data"
      work = described_class.new(data, 0, data.length)
      expect(work.data).to eq(data)
      expect(work.start).to eq(0)
      expect(work.length).to eq(data.length)
    end

    it "defaults length to data bytesize" do
      data = "test data"
      work = described_class.new(data, 0)
      expect(work.length).to eq(data.bytesize)
    end

    it "provides a string representation" do
      data = "test"
      work = described_class.new(data, 10, 4)
      expect(work.to_s).to include("start=10", "length=4")
    end
  end

  describe HierarchicalHasher::HashWorker do
    let(:worker) { described_class.new }

    it "calculates SHA-256 hash for chunk data" do
      data = "test data"
      work = HierarchicalHasher::ChunkWork.new(data, 0, data.length)
      result = worker.process(work)

      expect(result).to be_a(Fractor::WorkResult)
      expect(result.success?).to be true
      expect(result.result[:hash]).to be_a(String)
      expect(result.result[:hash].length).to eq(64) # SHA-256 produces 64 hex chars
      expect(result.result[:start]).to eq(0)
      expect(result.result[:length]).to eq(data.length)
    end

    it "produces consistent hashes for the same input" do
      data = "consistent data"
      work = HierarchicalHasher::ChunkWork.new(data, 0, data.length)

      result1 = worker.process(work)
      result2 = worker.process(work)

      expect(result1.result[:hash]).to eq(result2.result[:hash])
    end
  end

  describe HierarchicalHasher::FileHasher do
    let(:tempfile) { Tempfile.new(["test", ".txt"]) }
    let(:test_content) { "Line 1\nLine 2\nLine 3\n" * 10 }

    before do
      tempfile.write(test_content)
      tempfile.rewind
      tempfile.close
    end

    after do
      tempfile.unlink
    end

    it "initializes with file path and options" do
      hasher = described_class.new(tempfile.path, 1024, 2)
      expect(hasher.file_path).to eq(tempfile.path)
      expect(hasher.chunk_size).to eq(1024)
    end

    it "hashes a file using parallel workers" do
      hasher = described_class.new(tempfile.path, 100, 2)
      hash = hasher.hash_file

      expect(hash).to be_a(String)
      expect(hash.length).to eq(64) # SHA-256 produces 64 hex chars
      expect(hasher.final_hash).to eq(hash)
    end

    it "produces consistent hashes for the same file" do
      hasher1 = described_class.new(tempfile.path, 100, 2)
      hash1 = hasher1.hash_file

      hasher2 = described_class.new(tempfile.path, 100, 2)
      hash2 = hasher2.hash_file

      expect(hash1).to eq(hash2)
    end

    it "works with different chunk sizes" do
      hasher1 = described_class.new(tempfile.path, 50, 2)
      hash1 = hasher1.hash_file

      hasher2 = described_class.new(tempfile.path, 200, 2)
      hash2 = hasher2.hash_file

      # Different chunk sizes produce different intermediate hashes
      # so the final hash will be different
      expect(hash1).not_to eq(hash2)

      # But both should be valid SHA-256 hashes (64 hex characters)
      expect(hash1).to match(/\A[0-9a-f]{64}\z/i)
      expect(hash2).to match(/\A[0-9a-f]{64}\z/i)
    end

    it "works with different worker counts" do
      hasher1 = described_class.new(tempfile.path, 100, 1)
      hash1 = hasher1.hash_file

      hasher2 = described_class.new(tempfile.path, 100, 4)
      hash2 = hasher2.hash_file

      # Different worker counts should produce the same final hash
      expect(hash1).to eq(hash2)
    end
  end
end
