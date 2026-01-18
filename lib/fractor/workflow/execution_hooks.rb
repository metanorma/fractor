# frozen_string_literal: true

module Fractor
  class Workflow
    # Manages lifecycle hooks for workflow execution.
    # Allows registering callbacks for workflow/job lifecycle events.
    class ExecutionHooks
      def initialize
        @hooks = Hash.new { |h, k| h[k] = [] }
      end

      # Register a callback for a specific event.
      #
      # @param event [Symbol] The event to hook into
      # @yield [Object] Block to execute when event is triggered
      #
      # @example Register a workflow start hook
      #   hooks.register(:workflow_start) do |workflow|
      #     puts "Workflow starting: #{workflow.class.workflow_name}"
      #   end
      def register(event, &block)
        @hooks[event] << block
      end

      # Trigger all callbacks registered for an event.
      #
      # @param event [Symbol] The event to trigger
      # @param args [Array] Arguments to pass to the callbacks
      #
      # @example Trigger workflow completion
      #   hooks.trigger(:workflow_complete, result)
      def trigger(event, *args)
        @hooks[event].each do |hook|
          hook.call(*args)
        end
      end
    end
  end
end
