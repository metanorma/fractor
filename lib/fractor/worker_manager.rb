# frozen_string_literal: true

module Fractor
  # Manages worker Ractor lifecycle: creation, starting, and shutdown.
  # Extracted from Supervisor to follow Single Responsibility Principle.
  class WorkerManager
    attr_reader :workers, :worker_pools, :ractors_map

    def initialize(worker_pools, debug: false)
      @worker_pools = worker_pools
      @debug = debug
      @workers = []
      @ractors_map = {}
      @wakeup_ractor = nil
    end

    # Start all worker Ractors and the wakeup Ractor
    def start_all
      create_wakeup_ractor
      create_worker_pools
      flatten_workers
      compact_ractors_map

      return unless @debug

      puts "Workers started: #{@workers.size} active across #{@worker_pools.size} pools."
    end

    # Shutdown all workers
    def shutdown_all
      return if @workers.nil? || @workers.empty?

      @workers.each do |wrapped_ractor|
        wrapped_ractor.close if wrapped_ractor.respond_to?(:close)
      end

      @workers = []
      @ractors_map = {}
    end

    # Get idle (available) workers
    # Note: This is a simplified version. Full implementation would track
    # worker state across work distribution cycles.
    def idle_workers
      []
    end

    # Get busy (processing) workers
    # Note: This is a simplified version. Full implementation would track
    # worker state across work distribution cycles.
    def busy_workers
      []
    end

    # Get worker status summary
    def status_summary
      {
        total: @workers.size,
        idle: idle_workers.size,
        busy: busy_workers.size,
      }
    end

    private

    def create_wakeup_ractor
      @wakeup_ractor = Ractor.new do
        puts "Wakeup Ractor started" if @debug
        loop do
          msg = Ractor.receive
          puts "Wakeup Ractor received: #{msg.inspect}" if @debug
          if %i[wakeup shutdown].include?(msg)
            Ractor.yield({ type: :wakeup, message: msg })
            break if msg == :shutdown
          end
        end
        puts "Wakeup Ractor shutting down" if @debug
      end

      @ractors_map[@wakeup_ractor] = :wakeup
    end

    def create_worker_pools
      @worker_pools.each do |pool|
        worker_class = pool[:worker_class]
        num_workers = pool[:num_workers]

        pool[:workers] = (1..num_workers).map do |i|
          wrapped_ractor = WrappedRactor.new("worker #{worker_class}:#{i}", worker_class)
          wrapped_ractor.start
          @ractors_map[wrapped_ractor.ractor] = wrapped_ractor if wrapped_ractor.ractor
          wrapped_ractor
        end.compact
      end
    end

    def flatten_workers
      @workers = @worker_pools.flat_map { |pool| pool[:workers] }
    end

    def compact_ractors_map
      @ractors_map.compact!
    end
  end
end
