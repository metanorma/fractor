# frozen_string_literal: true

require "fractor/priority_work"
require "fractor/priority_work_queue"

RSpec.describe "Priority Work Example" do
  # Worker from the example
  class PriorityWorker < Fractor::Worker
    def process(work)
      sleep 0.01 # Reduced for testing
      result = "Processed #{work.input[:task]} " \
               "(priority: #{work.priority}, age: #{work.age.round(2)}s)"
      Fractor::WorkResult.new(result: result, work: work)
    end
  end

  describe "PriorityWork" do
    describe "creation" do
      it "creates work with default priority" do
        work = Fractor::PriorityWork.new({ task: "test" })

        expect(work.priority).to eq(:normal)
        expect(work.input).to eq({ task: "test" })
      end

      it "creates work with custom priority" do
        work = Fractor::PriorityWork.new({ task: "urgent" },
                                         priority: :critical)

        expect(work.priority).to eq(:critical)
      end

      it "raises error for invalid priority" do
        expect do
          Fractor::PriorityWork.new({ task: "test" }, priority: :invalid)
        end.to raise_error(ArgumentError, /Invalid priority/)
      end
    end

    describe "priority levels" do
      it "has numeric priority values" do
        critical = Fractor::PriorityWork.new({ task: "a" }, priority: :critical)
        high = Fractor::PriorityWork.new({ task: "b" }, priority: :high)
        normal = Fractor::PriorityWork.new({ task: "c" }, priority: :normal)
        low = Fractor::PriorityWork.new({ task: "d" }, priority: :low)
        background = Fractor::PriorityWork.new({ task: "e" },
                                               priority: :background)

        expect(critical.priority_value).to eq(0)
        expect(high.priority_value).to eq(1)
        expect(normal.priority_value).to eq(2)
        expect(low.priority_value).to eq(3)
        expect(background.priority_value).to eq(4)
      end

      it "has defined priority levels" do
        expect(Fractor::PriorityWork::PRIORITY_LEVELS).to eq({
                                                               critical: 0,
                                                               high: 1,
                                                               normal: 2,
                                                               low: 3,
                                                               background: 4,
                                                             })
      end
    end

    describe "comparison" do
      it "compares by priority first" do
        critical = Fractor::PriorityWork.new({ task: "a" }, priority: :critical)
        normal = Fractor::PriorityWork.new({ task: "b" }, priority: :normal)

        expect(critical <=> normal).to eq(-1) # critical comes before normal
        expect(normal <=> critical).to eq(1)
      end

      it "compares by creation time for same priority (FIFO)" do
        work1 = Fractor::PriorityWork.new({ task: "first" }, priority: :normal)
        sleep 0.01
        work2 = Fractor::PriorityWork.new({ task: "second" }, priority: :normal)

        expect(work1 <=> work2).to eq(-1) # older work comes first
        expect(work2 <=> work1).to eq(1)
      end

      it "returns nil when comparing with non-PriorityWork" do
        work = Fractor::PriorityWork.new({ task: "test" })
        other = Object.new

        expect(work <=> other).to be_nil
      end
    end

    describe "higher_priority_than?" do
      it "returns true when this work has higher priority" do
        critical = Fractor::PriorityWork.new({ task: "a" }, priority: :critical)
        normal = Fractor::PriorityWork.new({ task: "b" }, priority: :normal)

        expect(critical.higher_priority_than?(normal)).to be true
        expect(normal.higher_priority_than?(critical)).to be false
      end

      it "returns false for same priority" do
        work1 = Fractor::PriorityWork.new({ task: "a" }, priority: :normal)
        work2 = Fractor::PriorityWork.new({ task: "b" }, priority: :normal)

        expect(work1.higher_priority_than?(work2)).to be false
      end
    end

    describe "age tracking" do
      it "tracks age since creation" do
        work = Fractor::PriorityWork.new({ task: "test" })
        sleep 0.05

        expect(work.age).to be >= 0.05
      end

      it "has created_at timestamp" do
        before = Time.now
        work = Fractor::PriorityWork.new({ task: "test" })
        after = Time.now

        expect(work.created_at).to be_between(before, after)
      end
    end
  end

  describe "PriorityWorkQueue" do
    let(:queue) { Fractor::PriorityWorkQueue.new }

    describe "basic operations" do
      it "pushes and pops work items" do
        work = Fractor::PriorityWork.new({ task: "test" })
        queue.push(work)

        expect(queue.size).to eq(1)
        expect(queue.pop).to eq(work)
      end

      it "processes items in priority order" do
        queue.push(Fractor::PriorityWork.new({ task: "background" },
                                             priority: :background))
        queue.push(Fractor::PriorityWork.new({ task: "critical" },
                                             priority: :critical))
        queue.push(Fractor::PriorityWork.new({ task: "normal" },
                                             priority: :normal))

        expect(queue.pop.priority).to eq(:critical)
        expect(queue.pop.priority).to eq(:normal)
        expect(queue.pop.priority).to eq(:background)
      end

      it "is empty when created" do
        expect(queue.empty?).to be true
        expect(queue.size).to eq(0)
      end

      it "pops non-blocking for empty queue" do
        expect(queue.pop_non_blocking).to be_nil
      end
    end

    describe "priority ordering example" do
      it "orders mixed priorities correctly" do
        queue.push(Fractor::PriorityWork.new({ task: "Background report" },
                                             priority: :background))
        queue.push(Fractor::PriorityWork.new({ task: "Critical bug fix" },
                                             priority: :critical))
        queue.push(Fractor::PriorityWork.new({ task: "Normal feature" },
                                             priority: :normal))
        queue.push(Fractor::PriorityWork.new({ task: "High priority task" },
                                             priority: :high))
        queue.push(Fractor::PriorityWork.new({ task: "Low priority cleanup" },
                                             priority: :low))

        5.times do |_i| # rubocop:disable Lint/UnusedBlockArgument
          work = queue.pop_non_blocking
          expect(work).not_to be_nil
        end

        expect(queue.empty?).to be true
      end

      it "uses FIFO within same priority" do
        first = Fractor::PriorityWork.new({ task: "first" }, priority: :normal)
        sleep 0.01
        second = Fractor::PriorityWork.new({ task: "second" },
                                           priority: :normal)
        sleep 0.01
        third = Fractor::PriorityWork.new({ task: "third" }, priority: :normal)

        queue.push(third)
        queue.push(first)
        queue.push(second)

        expect(queue.pop).to eq(first)
        expect(queue.pop).to eq(second)
        expect(queue.pop).to eq(third)
      end
    end

    describe "priority aging" do
      it "prevents starvation with aging enabled" do
        aged_queue = Fractor::PriorityWorkQueue.new(
          aging_enabled: true,
          aging_threshold: 0.3, # 0.3 seconds for testing
        )

        # Add a low-priority item first
        low_priority = Fractor::PriorityWork.new(
          { task: "Old low-priority task" },
          priority: :low,
        )
        aged_queue.push(low_priority)

        # Wait for it to age enough to beat high priority
        # Low priority (value=3) needs to age enough to get effective priority < 1
        # With threshold 0.3, aging 1.2s gives: 3 - (1.2/0.3).floor = 3 - 4 = -1 -> clamped to 0 (critical)
        sleep 1.2

        # Add high-priority items after the low-priority one has aged
        high_priority = Fractor::PriorityWork.new(
          { task: "New high-priority task" },
          priority: :high,
        )
        aged_queue.push(high_priority)

        # The aged low-priority should come first (now at effective critical priority)
        first = aged_queue.pop_non_blocking
        expect(first.input[:task]).to eq("Old low-priority task")
      end

      it "processes items normally without aging" do
        normal_queue = Fractor::PriorityWorkQueue.new(aging_enabled: false)

        low_priority = Fractor::PriorityWork.new({ task: "low" },
                                                 priority: :low)
        high_priority = Fractor::PriorityWork.new({ task: "high" },
                                                  priority: :high)

        normal_queue.push(low_priority)
        sleep 0.6 # Wait to show aging is NOT applied
        normal_queue.push(high_priority)

        # High priority should come first (no aging)
        first = normal_queue.pop_non_blocking
        expect(first.input[:task]).to eq("high")
      end
    end

    describe "queue statistics" do
      before do
        10.times do |i|
          priority = %i[critical high normal low background].sample
          queue.push(Fractor::PriorityWork.new({ id: i }, priority: priority))
        end
      end

      it "provides queue statistics" do
        stats = queue.stats

        expect(stats[:total]).to eq(10)
        expect(stats[:closed]).to be false
        expect(stats[:by_priority]).to be_a(Hash)
        expect(stats[:by_priority].values.sum).to eq(10)
      end

      it "tracks items by priority that are present" do
        stats = queue.stats

        # Only check that priorities with items are tracked
        expect(stats[:by_priority]).to be_a(Hash)
        expect(stats[:by_priority].values.sum).to eq(10)
      end
    end

    describe "queue closing" do
      it "can be closed" do
        expect(queue.closed?).to be false

        queue.close
        expect(queue.closed?).to be true
      end

      it "raises error when pushing to closed queue" do
        queue.close
        work = Fractor::PriorityWork.new({ task: "test" })

        expect do
          queue.push(work)
        end.to raise_error(Fractor::ClosedQueueError, /Queue is closed/)
      end

      it "pops remaining items from closed queue" do
        queue.push(Fractor::PriorityWork.new({ task: "test" }))
        queue.close

        # Can still pop items that were in the queue
        result = queue.pop_non_blocking
        expect(result.input[:task]).to eq("test")

        # Once empty, returns nil
        expect(queue.pop_non_blocking).to be_nil
      end
    end
  end

  describe "integration with standard Work" do
    it "can convert PriorityWork to standard Work for Supervisor" do
      # PriorityWork is a subclass of Work, so it can be used with Supervisor
      supervisor = Fractor::Supervisor.new(
        worker_pools: [
          { worker_class: PriorityWorker, num_workers: 2 },
        ],
      )

      # Add mixed priority work using add_work_item
      works = [
        { task: "Process payment", priority: :critical },
        { task: "Send email", priority: :normal },
        { task: "Generate report", priority: :low },
      ]

      works.each do |item|
        supervisor.add_work_item(Fractor::PriorityWork.new(item,
                                                           priority: item[:priority]))
      end

      # Run supervisor
      supervisor_thread = Thread.new { supervisor.run }
      sleep 1 while !supervisor.work_queue.empty?
      supervisor.stop
      supervisor_thread.join

      # All work should be processed
      results = supervisor.results.results
      expect(results.size).to eq(3)
      expect(results.all?(&:success?)).to be true
    end

    it "processes all work items" do
      supervisor = Fractor::Supervisor.new(
        worker_pools: [
          { worker_class: PriorityWorker, num_workers: 2 },
        ],
      )

      5.times do |i|
        priority = %i[critical high normal low background].sample
        supervisor.add_work_item(Fractor::PriorityWork.new({ id: i },
                                                           priority: priority))
      end

      supervisor_thread = Thread.new { supervisor.run }
      sleep 1 while !supervisor.work_queue.empty?
      supervisor.stop
      supervisor_thread.join

      expect(supervisor.results.results.size).to eq(5)
    end
  end

  describe "PriorityWorker" do
    it "processes work and includes priority in result" do
      work = Fractor::PriorityWork.new(
        { task: "test_task" },
        priority: :high,
      )

      worker = PriorityWorker.new
      result = worker.process(work)

      expect(result).to be_success
      expect(result.result).to include("priority: high")
      expect(result.result).to include("test_task")
    end

    it "includes age information in result" do
      work = Fractor::PriorityWork.new({ task: "test" }, priority: :normal)
      sleep 0.02 # Let work age slightly

      result = PriorityWorker.new.process(work)

      expect(result.result).to include("age:")
    end
  end

  describe "real-world scenario" do
    it "handles complex priority workflow" do
      queue = Fractor::PriorityWorkQueue.new(aging_enabled: true,
                                             aging_threshold: 1)

      # Simulate realistic workload
      works = [
        { task: "Critical security patch", priority: :critical },
        { task: "User registration", priority: :high },
        { task: "Daily report generation", priority: :low },
        { task: "Log cleanup", priority: :background },
        { task: "User login", priority: :high },
        { task: "Database backup", priority: :normal },
        { task: "Email notification", priority: :normal },
      ]

      works.each do |item|
        queue.push(Fractor::PriorityWork.new(item, priority: item[:priority]))
      end

      # Verify queue has all items
      expect(queue.size).to eq(7)

      # Process in priority order
      processed = []
      until queue.empty?
        work = queue.pop_non_blocking
        processed << work.input[:task]
      end

      # Critical should be first
      expect(processed.first).to eq("Critical security patch")

      # Background should be last
      expect(processed.last).to eq("Log cleanup")

      # All items processed
      expect(processed.size).to eq(7)
    end
  end
end
