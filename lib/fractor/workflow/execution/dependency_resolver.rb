# frozen_string_literal: true

require "set"
require "digest"

module Fractor
  class Workflow
    # Computes the execution order for workflow jobs using topological sort.
    # Jobs are grouped into levels where all jobs in a level can be executed
    # in parallel (their dependencies are satisfied).
    #
    # Caches execution order based on job structure to avoid recomputing
    # topological sort for static workflow definitions.
    class DependencyResolver
      # Class-level cache for execution orders.
      # Keyed by workflow signature (hash of job structure).
      @cache = {}
      @mutex = Mutex.new

      class << self
        attr_reader :cache

        # Clear the entire execution order cache.
        # Useful for testing or when workflows are dynamically modified.
        def clear_cache
          @mutex.synchronize { @cache.clear }
        end

        # Clear cache entries for a specific workflow.
        #
        # @param workflow_signature [String] The workflow signature to clear
        def clear_cache_for(workflow_signature)
          @mutex.synchronize { @cache.delete(workflow_signature) }
        end
      end

      # Initialize the resolver with a workflow's jobs.
      #
      # @param jobs [Hash] Hash of job_name => Job objects
      # @param enable_cache [Boolean] Whether to use cached execution order (default: true)
      def initialize(jobs, enable_cache: true)
        @jobs = jobs
        @enable_cache = enable_cache
        @signature = compute_signature if enable_cache
      end

      # Compute the execution order using topological sort.
      # Returns an array of arrays, where each inner array contains job names
      # that can be executed in parallel (their dependencies are satisfied).
      #
      # Results are cached based on the workflow's job structure (job names
      # and their dependencies). This provides significant performance benefits
      # for workflows that are executed multiple times.
      #
      # @return [Array<Array<String>>] Execution order as grouped job names
      def execution_order
        # Try to get from cache first
        if @enable_cache && @signature && cached_execution_order
          return cached_execution_order
        end

        # Compute the execution order
        order = compute_order

        # Cache the result
        cache_execution_order(order) if @enable_cache && @signature

        order
      end

      # Invalidate the cache for this workflow's execution order.
      # Call this if the workflow definition changes dynamically.
      def invalidate_cache
        return unless @enable_cache && @signature

        self.class.clear_cache_for(@signature)
        @cached = false
      end

      private

      # Get the cached execution order for this workflow.
      #
      # @return [Array<Array<String>>, nil] Cached execution order or nil
      def cached_execution_order
        self.class.cache[@signature]
      end

      # Cache an execution order for this workflow.
      #
      # @param order [Array<Array<String>>] The execution order to cache
      def cache_execution_order(order)
        DependencyResolver.cache[@signature] = order
      end

      # Compute a unique signature for this workflow's job structure.
      # The signature is based on job names and their dependencies.
      #
      # @return [String] A hash representing the workflow structure
      def compute_signature
        # Build a deterministic representation of the workflow structure
        structure = {}
        @jobs.each do |name, job|
          structure[name] = {
            dependencies: Array(job.dependencies).sort,
          }
        end

        # Sort by job name for deterministic hashing
        sorted_structure = structure.sort.to_h

        # Generate SHA256 hash of the structure
        Digest::SHA256.hexdigest(JSON.dump(sorted_structure))
      end

      # Compute the execution order using topological sort.
      #
      # @return [Array<Array<String>>] Execution order as grouped job names
      def compute_order
        order = []
        remaining = @jobs.keys.to_set
        processed = Set.new

        until remaining.empty?
          # Find jobs whose dependencies are all satisfied
          ready = remaining.select do |job_name|
            job = @jobs[job_name]
            job.dependencies.all? { |dep| processed.include?(dep) }
          end

          if ready.empty?
            # This should not happen if validation was done correctly
            raise WorkflowExecutionError,
                  "Cannot find next jobs to execute. Remaining: #{remaining.to_a.join(', ')}"
          end

          order << ready
          ready.each do |job_name|
            processed.add(job_name)
            remaining.delete(job_name)
          end
        end

        puts "Execution order: #{order.inspect}" if ENV["FRACTOR_DEBUG"]
        order
      end
    end
  end
end
