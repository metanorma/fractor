# frozen_string_literal: true

module Fractor
  class Pool
    def initialize(size:)
      @size = size
      @workers = []
      @worker_ractors = {}
      @next_worker_id = 0
    end

    def add_worker(worker)
      worker.instance_variable_set(:@id, @next_worker_id)
      @workers << worker
      @next_worker_id += 1
    end

    def start_workers(supervisor)
      @workers.each do |worker|
        ractor = worker.start
        @worker_ractors[worker.id] = ractor
        supervisor.register_worker(worker.id, ractor)
      end
    end

    def health_check
      dead_workers = []

      @worker_ractors.each do |id, ractor|
        begin
          # Send ping to check if worker is alive
          ractor.send([:ping, {}])

          # Wait a short time for response
          timeout = 0.5
          start_time = Time.now

          loop do
            break if Time.now - start_time > timeout

            if Ractor.select(ractor, yield_value: true, timeout: 0.1)
              break
            end
          end

        rescue Ractor::RemoteError, Ractor::ClosedError => e
          # Worker is dead
          dead_workers << id
        end
      end

      dead_workers
    end

    def restart_worker(id)
      worker = @workers.find { |w| w.id == id }
      return false unless worker

      # Remove old ractor
      @worker_ractors.delete(id)

      # Create new ractor
      new_ractor = worker.start
      @worker_ractors[id] = new_ractor

      true
    end

    def all_idle?
      # This is a simplistic implementation - in a real system we'd track worker state
      true
    end

    def worker_count
      @workers.size
    end

    def active_workers
      @worker_ractors.keys
    end
  end
end
