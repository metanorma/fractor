# frozen_string_literal: true

module Fractor
  class Workflow
    # Manages data flow and state during workflow execution.
    # Stores workflow inputs, job outputs, and provides resolution of data dependencies.
    class WorkflowContext
      attr_reader :workflow_input, :job_outputs, :correlation_id, :logger

      def initialize(workflow_input, correlation_id: nil, logger: nil)
        @workflow_input = workflow_input
        @job_outputs = {}
        @correlation_id = correlation_id || generate_correlation_id
        @logger = logger || WorkflowLogger.new(correlation_id: @correlation_id)
      end

      # Store the output of a completed job.
      #
      # @param job_name [String] The job name
      # @param output [Lutaml::Model::Serializable] The job's output
      def store_job_output(job_name, output)
        @job_outputs[job_name] = output
      end

      # Get the output of a completed job.
      #
      # @param job_name [String] The job name
      # @return [Lutaml::Model::Serializable, nil] The job's output
      def job_output(job_name)
        @job_outputs[job_name]
      end

      # Build input for a job based on its input mappings.
      #
      # @param job [Job] The job to build input for
      # @return [Lutaml::Model::Serializable] The constructed input
      def build_job_input(job)
        return @workflow_input if job.input_mappings[:workflow]

        input_type = job.input_type
        unless input_type
          raise "Job '#{job.name}' has no input_type defined in its worker"
        end

        # Collect attributes from all mapped sources
        input_attrs = {}

        job.input_mappings.each do |source_job_name, attr_mappings|
          source_output = job_output(source_job_name)
          unless source_output
            raise "Job '#{job.name}' depends on '#{source_job_name}' but its output is not available"
          end

          if attr_mappings == :all
            # Map all attributes from source to input
            copy_all_attributes(source_output, input_attrs, input_type)
          else
            # Map specific attributes
            attr_mappings.each do |target_attr, source_attr|
              target_attr = target_attr.to_sym
              source_attr = source_attr.to_sym

              # Get value from source output
              value = if source_output.respond_to?(source_attr)
                        source_output.send(source_attr)
                      elsif source_output.respond_to?(:[])
                        source_output[source_attr]
                      else
                        raise "Source output from '#{source_job_name}' does not have attribute '#{source_attr}'"
                      end

              input_attrs[target_attr] = value
            end
          end
        end

        # Create input instance
        input_type.new(**input_attrs)
      end

      # Check if a job's output is available.
      #
      # @param job_name [String] The job name
      # @return [Boolean] Whether the output is available
      def job_completed?(job_name)
        @job_outputs.key?(job_name)
      end

      # Convert context to hash for debugging/logging
      def to_h
        {
          correlation_id: @correlation_id,
          workflow_input: @workflow_input.class.name,
          completed_jobs: @job_outputs.keys,
        }
      end

      private

      def generate_correlation_id
        require "securerandom"
        "wf-#{SecureRandom.hex(8)}"
      end

      def copy_all_attributes(source, target_hash, input_type)
        # Copy all compatible attributes from source to target
        if defined?(Lutaml::Model::Serializable) &&
            source.is_a?(Lutaml::Model::Serializable) &&
            input_type.respond_to?(:attributes)
          # Lutaml::Model path
          source.class.attributes.each_key do |attr_name|
            if input_type.attributes.key?(attr_name)
              target_hash[attr_name] = source.send(attr_name)
            end
          end
        else
          # Fallback for plain Ruby classes
          # Copy all instance variables from source that exist in target
          source.instance_variables.each do |var|
            attr_name = var.to_s.delete("@").to_sym

            # Check if target class has this attribute (via attr_accessor/reader)
            if input_type.instance_methods.include?(attr_name) ||
                input_type.instance_methods.include?("#{attr_name}=".to_sym)
              target_hash[attr_name] = source.instance_variable_get(var)
            end
          end
        end
      end
    end
  end
end
