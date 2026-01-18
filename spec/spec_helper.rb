# frozen_string_literal: true

require "fractor"

# Load support files
Dir[File.join(__dir__, "support", "**", "*.rb")].sort.each do |file|
  require file
end

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  # Reset Fractor global state before each test to ensure isolation
  # This is critical for test reliability and for scenarios where multiple
  # gems use Fractor together (they must not pollute each other's state)
  config.before do
    Fractor.reset!
  end

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end
