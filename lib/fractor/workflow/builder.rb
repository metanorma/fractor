# frozen_string_literal: true

module Fractor
  class Workflow
    # Programmatic API for building workflows without DSL
    # Useful for generating workflows dynamically
    #
    # Example:
    #   builder = Fractor::Workflow::Builder.new("my-workflow")
    #   builder.input_type(InputData)
    #   builder.output_type(OutputData)
    #   builder.add_job("process", ProcessWorker, inputs: :workflow)
    #   builder.add_job("finalize", FinalizeWorker, needs: "process", inputs: "process")
    #   workflow_class = builder.build
    #   workflow = workflow_class.new
    #   result = workflow.execute(input: data)
    class Builder
      attr_reader :name, :jobs, :input_type_class, :output_type_class

      def initialize(name)
        @name = name
        @jobs = []
        @input_type_class = nil
        @output_type_class = nil
      end

      # Set input type for the workflow
      def input_type(klass)
        @input_type_class = klass
        self
      end

      # Set output type for the workflow
      def output_type(klass)
        @output_type_class = klass
        self
      end

      # Add a job to the workflow
      #
      # @param id [String] Job identifier
      # @param worker [Class] Worker class
      # @param needs [String, Array<String>] Job dependencies
      # @param inputs [Symbol, String, Hash] Input configuration
      # @param condition [Proc] Conditional execution lambda
      # @param outputs_to_workflow [Boolean] Whether job outputs to workflow
      # @param terminates [Boolean] Whether job terminates workflow
      def add_job(id, worker, needs: nil, inputs: nil, condition: nil,
                  outputs_to_workflow: false, terminates: false)
        @jobs << {
          id: id,
          worker: worker,
          needs: needs,
          inputs: inputs,
          condition: condition,
          outputs_to_workflow: outputs_to_workflow,
          terminates: terminates,
        }
        self
      end

      # Remove a job by id
      def remove_job(id)
        @jobs.reject! { |j| j[:id] == id }
        self
      end

      # Update a job
      def update_job(id, **options)
        job = @jobs.find { |j| j[:id] == id }
        return self unless job

        job.merge!(options.compact)
        self
      end

      # Build the workflow class
      def build
        builder_name = @name
        builder_input_type = @input_type_class
        builder_output_type = @output_type_class
        builder_jobs = @jobs.dup

        # Define helper methods that will be available
        find_start_jobs_proc = lambda do |jobs|
          jobs.select { |j| j[:needs].nil? || j[:needs].empty? }
            .map { |j| j[:id] }
        end

        find_end_jobs_proc = lambda do |jobs|
          jobs.select { |j| j[:outputs_to_workflow] || j[:terminates] }
            .map { |j| j[:id] }
        end

        configure_inputs_proc = lambda do |job_dsl, inputs_config|
          return unless inputs_config

          case inputs_config
          when :workflow, "workflow"
            job_dsl.inputs_from_workflow
          when String
            job_dsl.inputs_from_job(inputs_config)
          when Hash
            if inputs_config[:from_job]
              job_dsl.inputs_from_job(inputs_config[:from_job])
            elsif inputs_config[:from_multiple]
              job_dsl.inputs_from_multiple(inputs_config[:from_multiple])
            end
          end
        end

        Class.new(Fractor::Workflow) do
          workflow builder_name do
            input_type builder_input_type if builder_input_type
            output_type builder_output_type if builder_output_type

            # Determine start and end jobs
            start_jobs = find_start_jobs_proc.call(builder_jobs)
            end_jobs = find_end_jobs_proc.call(builder_jobs)

            start_with(*start_jobs) if start_jobs.any?

            end_jobs.each do |end_job|
              end_with end_job, on: :success
            end

            # Define each job
            builder_jobs.each do |job_config|
              job_id = job_config[:id]
              worker_class = job_config[:worker]
              needs_list = job_config[:needs]
              inputs_config = job_config[:inputs]
              condition_proc = job_config[:condition]
              outputs = job_config[:outputs_to_workflow]
              terminates_flag = job_config[:terminates]

              job job_id do
                runs_with worker_class if worker_class

                if needs_list
                  needs_array = needs_list.is_a?(Array) ? needs_list : [needs_list]
                  needs(*needs_array)
                end

                configure_inputs_proc.call(self, inputs_config)

                if_condition condition_proc if condition_proc

                outputs_to_workflow if outputs || end_jobs.include?(job_id)
                terminates_workflow if terminates_flag || end_jobs.include?(job_id)
              end
            end
          end
        end
      end

      # Validate the workflow configuration
      def validate!
        if @name.nil? || @name.empty?
          raise ArgumentError,
                "Workflow must have a name"
        end
        if @jobs.empty?
          raise ArgumentError,
                "Workflow must have at least one job"
        end

        # Check for duplicate job IDs
        job_ids = @jobs.map { |j| j[:id] }
        duplicates = job_ids.select { |id| job_ids.count(id) > 1 }.uniq
        if duplicates.any?
          raise ArgumentError,
                "Duplicate job IDs: #{duplicates.join(', ')}"
        end

        # Check for missing dependencies
        @jobs.each do |job|
          needs = job[:needs]
          next unless needs

          needs_array = needs.is_a?(Array) ? needs : [needs]
          needs_array.each do |dep|
            unless job_ids.include?(dep)
              raise ArgumentError,
                    "Job '#{job[:id]}' depends on non-existent job '#{dep}'"
            end
          end
        end

        true
      end

      # Build and validate in one step
      def build!
        validate!
        build
      end

      # Clone this builder
      def clone
        new_builder = self.class.new(@name)
        new_builder.instance_variable_set(:@input_type_class, @input_type_class)
        new_builder.instance_variable_set(:@output_type_class,
                                          @output_type_class)
        new_builder.instance_variable_set(:@jobs, @jobs.dup)
        new_builder
      end
    end
  end
end
