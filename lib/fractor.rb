# frozen_string_literal: true

require_relative "fractor/version"
require_relative "fractor/message"
require_relative "fractor/message_handler"
require_relative "fractor/work"
require_relative "fractor/work_result"
require_relative "fractor/queue"
require_relative "fractor/worker"
require_relative "fractor/pool"
require_relative "fractor/result_assembler"
require_relative "fractor/supervisor"

module Fractor
  class Error < StandardError; end

  # Your code goes here...
end
