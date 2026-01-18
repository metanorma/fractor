# frozen_string_literal: true

require_relative "../../examples/specialized_workers/specialized_workers"

RSpec.describe SpecializedWorkers do
  describe SpecializedWorkers::ComputeWork do
    it "stores data, operation, and parameters" do
      work = described_class.new("data", :matrix_multiply, { size: [5, 5] })
      expect(work.data).to eq("data")
      expect(work.operation).to eq(:matrix_multiply)
      expect(work.parameters).to eq({ size: [5, 5] })
    end

    it "defaults to default operation" do
      work = described_class.new("data")
      expect(work.operation).to eq(:default)
    end

    it "defaults to empty parameters" do
      work = described_class.new("data", :image_transform)
      expect(work.parameters).to eq({})
    end

    it "provides a string representation" do
      work = described_class.new("data", :path_finding)
      expect(work.to_s).to include("ComputeWork", "path_finding")
    end
  end

  describe SpecializedWorkers::DatabaseWork do
    it "stores data, query_type, table, and conditions" do
      work = described_class.new("data", :select, "users", { active: true })
      expect(work.data).to eq("data")
      expect(work.query_type).to eq(:select)
      expect(work.table).to eq("users")
      expect(work.conditions).to eq({ active: true })
    end

    it "defaults to select query type" do
      work = described_class.new
      expect(work.query_type).to eq(:select)
    end

    it "provides a string representation" do
      work = described_class.new("", :insert, "orders")
      expect(work.to_s).to include("DatabaseWork", "insert", "orders")
    end
  end

  describe SpecializedWorkers::ComputeWorker do
    let(:worker) { described_class.new }

    it "processes ComputeWork for matrix operations" do
      work = SpecializedWorkers::ComputeWork.new("data", :matrix_multiply,
                                                 { size: [3, 3] })
      result = worker.process(work)

      expect(result).to be_a(Fractor::WorkResult)
      expect(result.success?).to be true
      expect(result.result[:operation]).to eq(:matrix_multiply)
      expect(result.result[:computation_result]).to include("Matrix multiplication")
    end

    it "processes ComputeWork for image transformations" do
      work = SpecializedWorkers::ComputeWork.new("data", :image_transform,
                                                 { transforms: [:rotate] })
      result = worker.process(work)

      expect(result.success?).to be true
      expect(result.result[:operation]).to eq(:image_transform)
      expect(result.result[:computation_result]).to include("Image transformation")
    end

    it "processes ComputeWork for path finding" do
      work = SpecializedWorkers::ComputeWork.new("data", :path_finding,
                                                 { algorithm: :dijkstra })
      result = worker.process(work)

      expect(result.success?).to be true
      expect(result.result[:operation]).to eq(:path_finding)
      expect(result.result[:computation_result]).to include("Path found")
    end

    it "rejects non-ComputeWork" do
      work = SpecializedWorkers::DatabaseWork.new
      result = worker.process(work)

      expect(result.success?).to be false
      expect(result.error).to include("can only process ComputeWork")
    end
  end

  describe SpecializedWorkers::DatabaseWorker do
    let(:worker) { described_class.new }

    it "processes DatabaseWork for select queries" do
      work = SpecializedWorkers::DatabaseWork.new("", :select, "users",
                                                  { active: true })
      result = worker.process(work)

      expect(result).to be_a(Fractor::WorkResult)
      expect(result.success?).to be true
      expect(result.result[:query_type]).to eq(:select)
      expect(result.result[:table]).to eq("users")
      expect(result.result[:rows_affected]).to be >= 0
    end

    it "processes DatabaseWork for insert queries" do
      work = SpecializedWorkers::DatabaseWork.new("data", :insert, "orders")
      result = worker.process(work)

      expect(result.success?).to be true
      expect(result.result[:query_type]).to eq(:insert)
      expect(result.result[:rows_affected]).to eq(1)
    end

    it "processes DatabaseWork for update queries" do
      work = SpecializedWorkers::DatabaseWork.new("data", :update, "products",
                                                  { id: 1 })
      result = worker.process(work)

      expect(result.success?).to be true
      expect(result.result[:query_type]).to eq(:update)
    end

    it "processes DatabaseWork for delete queries" do
      work = SpecializedWorkers::DatabaseWork.new("", :delete, "sessions",
                                                  { expired: true })
      result = worker.process(work)

      expect(result.success?).to be true
      expect(result.result[:query_type]).to eq(:delete)
    end

    it "rejects non-DatabaseWork" do
      work = SpecializedWorkers::ComputeWork.new("data")
      result = worker.process(work)

      expect(result.success?).to be false
      expect(result.error).to include("can only process DatabaseWork")
    end
  end

  describe SpecializedWorkers::HybridSystem do
    let(:system) { described_class.new(compute_workers: 1, db_workers: 1) }

    let(:compute_tasks) do
      [
        { operation: :matrix_multiply, data: "data",
          parameters: { size: [2, 2] } },
      ]
    end

    let(:db_tasks) do
      [
        { query_type: :select, table: "users", conditions: { active: true } },
      ]
    end

    it "processes mixed workload" do
      result = system.process_mixed_workload(compute_tasks, db_tasks)

      expect(result).to be_a(Hash)
      expect(result[:computation][:tasks]).to eq(1)
      expect(result[:database][:tasks]).to eq(1)
    end

    it "tracks compute results separately" do
      system.process_mixed_workload(compute_tasks, db_tasks)

      expect(system.compute_results).to be_an(Array)
      expect(system.compute_results).not_to be_empty
    end

    it "tracks database results separately" do
      system.process_mixed_workload(compute_tasks, db_tasks)

      expect(system.db_results).to be_an(Array)
      expect(system.db_results).not_to be_empty
    end

    it "handles empty compute tasks" do
      result = system.process_mixed_workload([], db_tasks)

      expect(result[:computation][:tasks]).to eq(0)
      expect(result[:database][:tasks]).to eq(1)
    end

    it "handles empty database tasks" do
      result = system.process_mixed_workload(compute_tasks, [])

      expect(result[:computation][:tasks]).to eq(1)
      expect(result[:database][:tasks]).to eq(0)
    end
  end
end
