# frozen_string_literal: true

module Fractor
  class Workflow
    # Generates visual representations of workflows.
    # Supports Mermaid, DOT/Graphviz, and ASCII art formats.
    class Visualizer
      def initialize(workflow_class)
        @workflow_class = workflow_class
        @jobs = workflow_class.jobs
      end

      # Generate Mermaid flowchart diagram
      #
      # @return [String] Mermaid diagram syntax
      def to_mermaid
        lines = ["flowchart TD"]
        lines << "    Start([Start: #{@workflow_class.workflow_name}])"

        # Add job nodes
        @jobs.each do |name, job|
          label = escape_mermaid(name)
          worker = escape_mermaid(job.worker_class.name.split("::").last)

          # Different shapes based on job type
          lines << if job.terminates
                     "    #{node_id(name)}[/#{label}<br/>#{worker}/]"
                   else
                     "    #{node_id(name)}[#{label}<br/>#{worker}]"
                   end
        end

        lines << "    End([End])"

        # Add edges
        @jobs.each do |name, job|
          if job.dependencies.empty?
            # Start job
            lines << "    Start --> #{node_id(name)}"
          else
            # Dependencies
            job.dependencies.each do |dep|
              edge_label = ""
              if job.condition_proc
                edge_label = "|conditional|"
              end
              lines << "    #{node_id(dep)} -->#{edge_label} #{node_id(name)}"
            end
          end

          # Terminating jobs
          if job.terminates
            lines << "    #{node_id(name)} --> End"
          end
        end

        # Add styling
        lines << ""
        lines << "    classDef terminating fill:#f9f,stroke:#333,stroke-width:2px"
        @jobs.each do |name, job|
          lines << "    class #{node_id(name)} terminating" if job.terminates
        end

        lines.join("\n")
      end

      # Generate DOT/Graphviz diagram
      #
      # @return [String] DOT syntax
      def to_dot
        lines = ["digraph #{dot_id(@workflow_class.workflow_name)} {"]
        lines << "  rankdir=TD;"
        lines << "  node [shape=box, style=rounded];"
        lines << ""

        # Start node
        lines << '  start [label="Start", shape=ellipse];'

        # Job nodes
        @jobs.each do |name, job|
          worker = job.worker_class.name
          label = "#{name}\\n(#{worker})"

          lines << if job.terminates
                     "  #{dot_id(name)} [label=\"#{label}\", " \
                              "style=\"rounded,filled\", fillcolor=lightpink];"
                   else
                     "  #{dot_id(name)} [label=\"#{label}\"];"
                   end
        end

        # End node
        lines << '  end [label="End", shape=ellipse];'
        lines << ""

        # Edges
        @jobs.each do |name, job|
          if job.dependencies.empty?
            lines << "  start -> #{dot_id(name)};"
          else
            job.dependencies.each do |dep|
              lines << if job.condition_proc
                         "  #{dot_id(dep)} -> #{dot_id(name)} " \
                                  "[label=\"conditional\", style=dashed];"
                       else
                         "  #{dot_id(dep)} -> #{dot_id(name)};"
                       end
            end
          end

          if job.terminates
            lines << "  #{dot_id(name)} -> end;"
          end
        end

        lines << "}"
        lines.join("\n")
      end

      # Generate ASCII art diagram
      #
      # @return [String] ASCII art representation
      def to_ascii
        lines = []
        lines << "┌─────────────────────────────────────────┐"
        lines << "│ Workflow: #{@workflow_class.workflow_name.ljust(27)} │"
        lines << "└─────────────────────────────────────────┘"
        lines << ""

        # Compute execution order
        order = compute_execution_order

        order.each_with_index do |job_group, index|
          if job_group.size == 1
            # Single job
            job = @jobs[job_group.first]
            lines << "    ┌─────────────────────────┐"
            lines << "    │ #{job_group.first.ljust(23)} │"
            lines << "    │ (#{job.worker_class.name.split('::').last.ljust(21)}) │"
            lines << "    └─────────────────────────┘"
          else
            # Parallel jobs
            lines << "    ╔═════════════════════════╗"
            lines << "    ║ PARALLEL EXECUTION      ║"
            lines << "    ╚═════════════════════════╝"
            job_group.each do |job_name|
              job = @jobs[job_name]
              lines << "        ├─ #{job_name}"
              lines << "        │  (#{job.worker_class.name.split('::').last})"
            end
          end

          # Arrow to next group
          if index < order.size - 1
            lines << "           │"
            lines << "           ▼"
          end
        end

        lines << ""
        lines << "Legend: Regular jobs │ Parallel jobs ╔═══╗"

        lines.join("\n")
      end

      # Print ASCII diagram to stdout
      def print
        puts to_ascii
      end

      private

      def node_id(name)
        name.to_s.gsub(/[^a-zA-Z0-9_]/, "_")
      end

      def dot_id(name)
        name.to_s.gsub(/[^a-zA-Z0-9_]/, "_")
      end

      def escape_mermaid(text)
        text.to_s.gsub(/["\[\]()]/, "")
      end

      def compute_execution_order
        # Topological sort
        jobs = @jobs
        order = []
        remaining = jobs.keys.to_set
        processed = Set.new

        until remaining.empty?
          ready = remaining.select do |job_name|
            job = jobs[job_name]
            job.dependencies.all? { |dep| processed.include?(dep) }
          end

          break if ready.empty?

          order << ready
          ready.each do |job_name|
            processed.add(job_name)
            remaining.delete(job_name)
          end
        end

        order
      end
    end
  end
end
