# frozen_string_literal: true

module Fractor
  # Base class for defining work processors.
  # Subclasses must implement the `process` method.
  class Worker
    def initialize(name: nil, **options)
      @name = name
      @options = options
    end

    def process(work)
      raise NotImplementedError, "Subclasses must implement the 'process' method."
    end
  end
end
