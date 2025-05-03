# frozen_string_literal: true

module Fractor
  class Supervisor
    @@message_specs = {}
    @@message_handlers = {}

    class << self
      # Define a message type at the class level
      def message(type, &spec_block)
        @@message_specs[type] = spec_block

        # Register with global Message class if not already registered
        unless Message.registered_types.include?(type)
          Message.message(type, &spec_block)
        end
      end

      # Define a message handler
      def handle_message(type, &block)
        @@message_handlers[self] ||= {}
        @@message_handlers[self][type] = block
      end

      # Get all message handlers for this supervisor class
      def message_handlers
        @@message_handlers[self] || {}
      end
    end

    def initialize
      @pools = []
      @queues = []
      @active_workers = {}
      @worker_last_seen = {}
      @failed_works = {}
      @monitor_thread = nil
      @message_handler = MessageHandler.new
      @result_queue = Queue.new

      # Initialize message handlers
      self.class.message_handlers.each do |type, handler|
        @message_handler.register(type) do |params|
          instance_exec(params, &handler)
        end
      end

      # Register standard message handlers
      register_standard_handlers
    end

    def register_standard_handlers
      @message_handler.register(:result) do |params|
        result = params[:result]
        handle_worker_result(result)
      end

      @message_handler.register(:error) do |params|
        work = params[:work]
        error = params[:error_details]
        worker_id = params[:worker_id]
        handle_worker_errors(worker_id, work, error)
      end

      @message_handler.register(:pong) do |params|
        # Track worker heartbeat
        worker_id = params[:worker_id]
        @worker_last_seen[worker_id] = Time.now
      end

      @message_handler.register(:fatal_error) do |params|
        error = params[:error_details]
        worker_id = params[:worker_id]
        handle_worker_fatal_error(worker_id, error)
      end
    end

    def add_queue(queue)
      @queues << queue
    end

    def add_pool(pool)
      @pools << pool
    end

    def register_worker(worker_id, worker_ractor)
      @active_workers[worker_id] = worker_ractor
      @worker_last_seen[worker_id] = Time.now
    end

    def send_message(worker_id, message)
      worker = @active_workers[worker_id]
      if worker
        worker.send(message.to_a)
      else
        raise "Unknown worker ID: #{worker_id}"
      end
    end

    def broadcast_message(message)
      @active_workers.each do |worker_id, worker|
        worker.send(message.to_a)
      end
    end

    def start
      # Start all workers
      @pools.each do |pool|
        pool.start_workers(self)
      end

      # Start the worker monitor thread
      @monitor_thread = Thread.new do
        monitor_workers
      end

      # Start the main work distribution loop
      distribute_work

      # Process results
      process_results
    end

    def distribute_work
      # This is a basic implementation - subclasses should override for specific strategies
      until @queues.all?(&:empty?)
        @queues.each do |queue|
          next if queue.empty?

          # Find an available worker
          worker_id = @active_workers.keys.sample
          next unless worker_id

          # Get work from queue
          work = queue.pop
          next unless work

          # Send work to worker
          begin
            send_message(worker_id, Message.new(type: :process, params: { work: work }))
          rescue => e
            # If sending fails, put work back in queue
            queue.push(work)
          end
        end

        # Small sleep to prevent CPU spinning
        sleep 0.01
      end
    end

    def handle_worker_result(result)
      @result_queue << [:result, result]
    end

    def handle_worker_errors(worker_id, work, error)
      if work
        work.failed

        if work.should_retry?
          # Put work back in queue for retry
          queue = find_queue_for_work(work)
          queue.push(work) if queue
        else
          # Work has exceeded retry limit
          @failed_works[work.object_id] = { work: work, error: error }

          # Notify assembler if configured
          @assembler&.add_failed_work(work, error)
        end
      end

      @result_queue << [:error, work, error]
    end

    def handle_worker_fatal_error(worker_id, error)
      # Log the error
      puts "Fatal error in worker #{worker_id}: #{error[:message]}"

      # Restart the worker
      restart_dead_worker(worker_id)
    end

    def next_result
      @result_queue.pop(true) rescue nil
    end

    def monitor_workers
      loop do
        @pools.each do |pool|
          dead_workers = pool.health_check

          dead_workers.each do |worker_id|
            restart_dead_worker(worker_id)
          end
        end

        sleep 1 # Check every second
      end
    rescue => e
      puts "Monitor thread error: #{e.message}"
      retry
    end

    def restart_dead_worker(worker_id)
      # Find the pool containing this worker
      @pools.each do |pool|
        if pool.restart_worker(worker_id)
          # Worker restarted successfully
          return true
        end
      end

      false
    end

    def find_queue_for_work(work)
      @queues.find { |q| q.work_types.include?(work.work_type) }
    end

    def process_results
      # This is a basic implementation - subclasses should override for specific strategies
      until @queues.all?(&:empty?) && @active_workers.empty?
        result = next_result
        break if result.nil?

        # Process the result based on its type
        case result.first
        when :result
          # Handle successful result
          # Subclasses should override this
        when :error
          # Handle error
          # Subclasses should override this
        end
      end
    end

    def shutdown
      # Stop the monitor thread
      @monitor_thread&.kill

      # Terminate all workers
      broadcast_message(Message.new(type: :terminate))

      # Wait for workers to terminate
      sleep 0.1
    end
  end
end
