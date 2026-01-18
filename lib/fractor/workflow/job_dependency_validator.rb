# frozen_string_literal: true

module Fractor
  class Workflow
    # Validates job dependencies in workflows.
    # Ensures dependencies exist and are acyclic.
    #
    # This validator prevents runtime errors by catching configuration
    # issues before workflow execution begins.
    class JobDependencyValidator
      # Error raised when dependency validation fails.
      class DependencyError < StandardError; end

      def initialize(jobs)
        @jobs = jobs
        @jobs_by_name = build_jobs_index
      end

      # Validate all job dependencies.
      # Raises DependencyError if any validation fails.
      #
      # @raise [DependencyError] if validation fails
      # @return [true] if validation passes
      def validate!
        check_missing_dependencies
        check_circular_dependencies
        true
      end

      # Check for circular dependencies using depth-first search.
      #
      # @raise [DependencyError] if circular dependencies found
      # @return [true] if no circular dependencies
      def check_circular_dependencies
        visited = Set.new
        path = [] # Track current path as an array

        @jobs.each do |job|
          next if visited.include?(job.name)

          cycle = dfs_cycle_check(job, visited, path)
          if cycle
            cycle_path = cycle.join(" -> ")
            raise DependencyError, "Circular dependency detected: #{cycle_path}"
          end
        end

        true
      end

      # DFS cycle detection that returns the cycle path if found.
      #
      # @param job [Job] The job to check
      # @param visited [Set] Jobs already visited
      # @param path [Array] Current path being explored
      # @return [Array<String>, nil] Cycle path if found, nil otherwise
      def dfs_cycle_check(job, visited, path)
        return nil unless job

        # If this job is in the current path, we found a cycle
        if path.include?(job.name)
          # Extract the cycle portion
          cycle_start_index = path.index(job.name)
          return path[cycle_start_index..] + [job.name]
        end

        # If we've already fully explored this job, no cycle from here
        return nil if visited.include?(job.name)

        # Add to current path
        path << job.name

        # Check all dependencies
        job.dependencies.each do |dep_name|
          dep_job = @jobs_by_name[dep_name]
          next unless dep_job

          cycle = dfs_cycle_check(dep_job, visited, path)
          return cycle if cycle
        end

        # Remove from path and mark as visited
        path.pop
        visited.add(job.name)

        nil
      end

      # Check that all job dependencies exist.
      #
      # @raise [DependencyError] if any dependencies are missing
      # @return [true] if all dependencies exist
      def check_missing_dependencies
        missing = []

        @jobs.each do |job|
          job.dependencies.each do |dep_name|
            unless @jobs_by_name.key?(dep_name)
              missing << "#{job.name} depends on non-existent job '#{dep_name}'"
            end
          end
        end

        return true if missing.empty?

        raise DependencyError,
              "Missing dependencies:\n  - #{missing.join("\n  - ")}"
      end

      private

      # Build an index of jobs by name for quick lookup.
      #
      # @return [Hash<String, Job>]
      def build_jobs_index
        @jobs.each_with_object({}) { |job, hash| hash[job.name] = job }
      end
    end
  end
end
