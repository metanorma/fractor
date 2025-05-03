# frozen_string_literal: true

module Fractor
  class Queue
    attr_reader :work_types

    def initialize(work_types: [])
      @work_types = work_types
      @work_queue = []
      @failed_queue = []
    end

    def push(work)
      unless @work_types.include?(work.work_type)
        raise ArgumentError, "Unsupported work type: #{work.work_type}"
      end

      @work_queue.push(work)
    end

    def pop
      @work_queue.shift
    end

    def size
      @work_queue.size
    end

    def empty?
      @work_queue.empty?
    end

    def push_failed(work, error)
      @failed_queue.push({ work: work, error: error })
    end

    def failed_count
      @failed_queue.size
    end

    def failed_works
      @failed_queue.dup
    end
  end
end
