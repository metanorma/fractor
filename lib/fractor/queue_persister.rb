# frozen_string_literal: true

require "json"
require "yaml"

module Fractor
  # Persistence strategies for work queues.
  # Provides different backends for saving and loading queue state.
  module QueuePersister
    # Base class for queue persisters.
    #
    # @abstract Subclasses must implement {#save} and {#load}
    class Base
      # Save work items to persistent storage.
      #
      # @abstract
      # @param items [Array<Fractor::Work>] Work items to save
      # @return [Boolean] true if saved successfully
      def save(_items)
        raise NotImplementedError, "Subclasses must implement #save"
      end

      # Load work items from persistent storage.
      #
      # @abstract
      # @return [Array<Hash>, nil] Serialized work items, or nil if no data
      def load
        raise NotImplementedError, "Subclasses must implement #load"
      end

      # Clear persisted data.
      #
      # @abstract
      # @return [Boolean] true if cleared successfully
      def clear
        raise NotImplementedError, "Subclasses must implement #clear"
      end

      protected

      # Serialize a work item to a hash.
      #
      # @param work [Fractor::Work] The work item to serialize
      # @return [Hash] Serialized work item
      def serialize_work(work)
        hash = {
          _class: work.class.name,
          _input: work.input,
        }
        hash[:_timeout] = work.timeout if work.respond_to?(:timeout) && !work.timeout.nil?
        hash
      end
    end

    # JSON file persister.
    # Stores queue state as a JSON array.
    class JSONPersister < Base
      # Initialize a JSON persister.
      #
      # @param path [String] Path to the JSON file
      # @param pretty [Boolean] Format JSON with indentation
      def initialize(path, pretty: true)
        @path = path
        @pretty = pretty
      end

      # Save work items to JSON file.
      #
      # @param items [Array<Fractor::Work>] Work items to save
      # @return [Boolean] true if saved successfully
      def save(items)
        ensure_directory_exists

        serialized = items.map { |work| serialize_work(work) }
        json = @pretty ? JSON.pretty_generate(serialized) : JSON.generate(serialized)

        File.write(@path, json)
        true
      rescue StandardError => e
        warn "Failed to save to #{@path}: #{e.message}"
        false
      end

      # Load work items from JSON file.
      #
      # @return [Array<Hash>, nil] Serialized work items, or nil if file doesn't exist
      def load
        return nil unless File.exist?(@path)

        json = File.read(@path)
        return nil if json.strip.empty?

        JSON.parse(json)
      rescue StandardError => e
        warn "Failed to load from #{@path}: #{e.message}"
        nil
      end

      # Clear the JSON file.
      #
      # @return [Boolean] true if cleared successfully
      def clear
        File.delete(@path) if File.exist?(@path)
        true
      rescue StandardError => e
        warn "Failed to clear #{@path}: #{e.message}"
        false
      end

      private

      # Ensure the directory for the file exists.
      #
      # @return [void]
      def ensure_directory_exists
        dir = File.dirname(@path)
        FileUtils.mkdir_p(dir) unless Dir.exist?(dir)
      end
    end

    # YAML file persister.
    # Stores queue state as a YAML document.
    class YAMLPersister < Base
      # Initialize a YAML persister.
      #
      # @param path [String] Path to the YAML file
      def initialize(path)
        @path = path
      end

      # Save work items to YAML file.
      #
      # @param items [Array<Fractor::Work>] Work items to save
      # @return [Boolean] true if saved successfully
      def save(items)
        ensure_directory_exists

        serialized = items.map { |work| serialize_work(work) }
        yaml = YAML.dump(serialized)

        File.write(@path, yaml)
        true
      rescue StandardError => e
        warn "Failed to save to #{@path}: #{e.message}"
        false
      end

      # Load work items from YAML file.
      #
      # @return [Array<Hash>, nil] Serialized work items, or nil if file doesn't exist
      def load
        return nil unless File.exist?(@path)

        yaml = File.read(@path)
        return nil if yaml.strip.empty?

        YAML.safe_load(yaml, permitted_classes: [Symbol, Hash, String, Integer, Float, TrueClass, FalseClass, NilClass])
      rescue StandardError => e
        warn "Failed to load from #{@path}: #{e.message}"
        nil
      end

      # Clear the YAML file.
      #
      # @return [Boolean] true if cleared successfully
      def clear
        File.delete(@path) if File.exist?(@path)
        true
      rescue StandardError => e
        warn "Failed to clear #{@path}: #{e.message}"
        false
      end

      private

      # Ensure the directory for the file exists.
      #
      # @return [void]
      def ensure_directory_exists
        dir = File.dirname(@path)
        FileUtils.mkdir_p(dir) unless Dir.exist?(dir)
      end
    end

    # Marshal file persister.
    # Uses Ruby's Marshal for binary serialization.
    # Note: Marshal is not secure and should not be used with untrusted data.
    class MarshalPersister < Base
      # Initialize a Marshal persister.
      #
      # @param path [String] Path to the Marshal file
      def initialize(path)
        @path = path
      end

      # Save work items using Marshal.
      #
      # @param items [Array<Fractor::Work>] Work items to save
      # @return [Boolean] true if saved successfully
      def save(items)
        ensure_directory_exists

        serialized = items.map { |work| serialize_work(work) }
        data = Marshal.dump(serialized)

        File.binwrite(@path, data)
        true
      rescue StandardError => e
        warn "Failed to save to #{@path}: #{e.message}"
        false
      end

      # Load work items using Marshal.
      #
      # @return [Array<Hash>, nil] Serialized work items, or nil if file doesn't exist
      def load
        return nil unless File.exist?(@path)

        data = File.binread(@path)
        Marshal.load(data)
      rescue StandardError => e
        warn "Failed to load from #{@path}: #{e.message}"
        nil
      end

      # Clear the Marshal file.
      #
      # @return [Boolean] true if cleared successfully
      def clear
        File.delete(@path) if File.exist?(@path)
        true
      rescue StandardError => e
        warn "Failed to clear #{@path}: #{e.message}"
        false
      end

      private

      # Ensure the directory for the file exists.
      #
      # @return [void]
      def ensure_directory_exists
        dir = File.dirname(@path)
        FileUtils.mkdir_p(dir) unless Dir.exist?(dir)
      end
    end
  end
end
