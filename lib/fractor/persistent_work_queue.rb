# frozen_string_literal: true

require_relative "work_queue"
require_relative "queue_persister"
require "json"

module Fractor
  # A work queue with persistence support.
  # Automatically saves queue state to disk for crash recovery.
  #
  # @example Basic usage
  #   queue = PersistentWorkQueue.new("data/queue.json")
  #   queue << work_item  # Automatically saved
  #
  # @example With custom persister
  #   persister = QueuePersister::YAMLPersister.new("data/queue.yml")
  #   queue = PersistentWorkQueue.new(persister: persister)
  class PersistentWorkQueue < WorkQueue
    attr_reader :persister

    # Initialize a persistent work queue.
    #
    # @param path_or_persister [String, QueuePersister::Base] File path or persister instance
    # @param auto_save [Boolean] Automatically save after each enqueue
    # @param save_interval [Integer, nil] Seconds between auto-saves (nil = disabled)
    def initialize(path_or_persister = nil, auto_save: true, save_interval: nil)
      super()

      @persister = case path_or_persister
                   when String
                     QueuePersister::JSONPersister.new(path_or_persister)
                   when QueuePersister::Base, nil
                     path_or_persister
                   else
                     raise ArgumentError,
                           "path_or_persister must be a String or QueuePersister::Base"
                   end

      @auto_save = @persister ? auto_save : false
      @save_interval = save_interval
      @dirty = false
      @save_thread = nil

      # Start auto-save thread if interval is specified
      start_save_thread if @save_interval
    end

    # Add a work item to the queue with automatic persistence.
    #
    # @param work_item [Fractor::Work] The work item to add
    # @return [void]
    def enqueue(work_item)
      super
      @dirty = true
      save if @auto_save
    end

    # Alias for enqueue
    #
    # @param work_item [Fractor::Work] The work item to add
    # @return [void]
    def <<(work_item)
      enqueue(work_item)
    end

    # Retrieve multiple work items from the queue.
    # Marks queue as dirty for persistence.
    #
    # @param max_items [Integer] Maximum number of items to retrieve
    # @return [Array<Fractor::Work>] Array of work items
    def dequeue_batch(max_items = 10)
      items = super
      @dirty = true if items.any?
      items
    end

    # Save the current queue state to disk.
    #
    # @return [Boolean] true if saved successfully
    def save
      return false unless @persister

      # Get all items from the queue without removing them
      items = peek_all
      @persister.save(items)
      @dirty = false
      true
    rescue StandardError => e
      warn "Failed to save queue: #{e.message}"
      false
    end

    # Load queue state from disk, restoring previous work items.
    #
    # @return [Integer] Number of items restored
    def load
      return 0 unless @persister

      items = @persister.load
      return 0 unless items

      count = 0
      items.each do |item|
        # Convert hash back to Work object if needed
        work = if item.is_a?(Hash)
                 deserialize_work(item)
               else
                 item
               end

        @queue << work if work.is_a?(Fractor::Work)
        count += 1
      end

      @dirty = false
      count
    rescue StandardError => e
      warn "Failed to load queue: #{e.message}"
      0
    end

    # Clear the queue and remove persisted data.
    #
    # @return [Boolean] true if cleared successfully
    def clear
      @queue.clear
      @persister&.clear
      @dirty = false
      true
    rescue StandardError => e
      warn "Failed to clear queue: #{e.message}"
      false
    end

    # Check if the queue has unsaved changes.
    #
    # @return [Boolean] true if there are unsaved changes
    def dirty?
      @dirty
    end

    # Save and close the queue, cleaning up resources.
    #
    # @return [void]
    def close
      save if @dirty
      stop_save_thread if @save_thread
    end

    private

    # Peek at all items in the queue without removing them.
    #
    # @return [Array<Fractor::Work>] All work items in the queue
    def peek_all
      items = []
      # Thread::Queue doesn't have a peek method, so we need to
      # temporarily remove items, collect them, and put them back
      temp = []
      until @queue.empty?
        item = @queue.pop(true)
        temp << item
        items << item
      end
      # Put items back
      temp.each { |item| @queue << item }
      items
    rescue ThreadError
      # Queue became empty during iteration
      items
    end

    # Deserialize a work item from a hash.
    #
    # @param hash [Hash] The serialized work item
    # @return [Fractor::Work, nil] The deserialized work item
    def deserialize_work(hash)
      return nil unless hash.is_a?(Hash)

      # Extract class name and data (handle both string and symbol keys for JSON compatibility)
      hash.delete(:_class) || hash.delete("_class")
      input_data = hash.delete(:_input) || hash.delete("_input")
      timeout = hash.delete(:_timeout) || hash.delete("_timeout")

      # For simplicity, always use the base Work class with stored input
      # This ensures correct deserialization without complex reflection
      if timeout
        Fractor::Work.new(input_data, timeout: timeout)
      else
        Fractor::Work.new(input_data)
      end
    rescue StandardError => e
      warn "Failed to deserialize work item: #{e.message}"
      nil
    end

    # Start the auto-save thread.
    #
    # @return [void]
    def start_save_thread
      @save_thread = Thread.new do
        loop do
          sleep @save_interval
          save if @dirty
        end
      end
      @save_thread.name = "PersistentWorkQueue-auto-save" if @save_thread.respond_to?(:name=)
    end

    # Stop the auto-save thread.
    #
    # @return [void]
    def stop_save_thread
      @save_thread&.kill
      @save_thread = nil
    end
  end
end
