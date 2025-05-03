# frozen_string_literal: true

module Fractor
  class ResultAssembler
    def initialize
      @results = []
      @failed_works = []
    end

    def add_result(result)
      @results << result
    end

    def add_failed_work(work, error)
      @failed_works << { work: work, error: error }
    end

    def finalize
      # To be overridden by subclasses
      raise NotImplementedError, "Subclasses must implement finalize method"
    end

    def results
      @results.dup
    end

    def failed_works
      @failed_works.dup
    end

    def has_failures?
      @failed_works.any?
    end
  end
end
