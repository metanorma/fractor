# frozen_string_literal: true

module Fractor
  class WorkResult
    attr_reader :original_work, :result, :success, :error

    def initialize(original_work:, result: nil, success: true, error: nil)
      @original_work = original_work
      @result = result
      @success = success
      @error = error
    end

    def successful?
      @success
    end
  end
end
