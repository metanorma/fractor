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

  # Skip tests tagged with :ruby3 when running on Ruby 4.0+
  # Ruby 4.0 has different Ractor behavior (no :initialize messages, port-based communication)
  config.before(:each, :ruby3) do
    skip("Ruby 3.x specific test, skipped on Ruby 4.0+") if Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("4.0.0")
  end

  # Skip tests tagged with :ruby4 when running on Ruby 3.x
  # Ruby 4.0+ specific tests use Ractor::Port and other features not available in Ruby 3.x
  config.before(:each, :ruby4) do
    skip("Ruby 4.0+ specific test, skipped on Ruby 3.x") if Gem::Version.new(RUBY_VERSION) < Gem::Version.new("4.0.0")
  end

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
