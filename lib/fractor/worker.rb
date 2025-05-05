# frozen_string_literal: true

module Fractor
  # Base class for defining work processors.
  # Subclasses must implement the `process` method.
  class Worker
    def process(work)
      raise NotImplementedError, "Subclasses must implement the 'process' method."
    end
  end
end
