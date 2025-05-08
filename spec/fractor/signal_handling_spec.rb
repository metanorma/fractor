# frozen_string_literal: true

require "spec_helper"
require "open3"
require "timeout"

RSpec.describe "Signal handling in Fractor" do
  # Path to our test fixture
  let(:fixture_script) { File.join(File.dirname(__FILE__), "..", "fixtures", "long_running_fractor.rb") }

  describe "Ctrl+C (SIGINT) handling" do
    # Skip these tests on Windows with Ruby 3.4
    skip "This hangs on Windows with Ruby 3.4" if RUBY_PLATFORM.match?(/mingw|mswin|cygwin/) && RUBY_VERSION.start_with?("3.4")
    it "properly terminates when receiving a SIGINT signal" do
      # Use popen3 to start the fixture script as a separate process and capture output
      pid = nil
      # Use sync: true to avoid output buffering
      stdin, stdout, stderr, wait_thread = Open3.popen3("ruby #{fixture_script}")

      # Make stdout and stderr non-blocking
      stdout.sync = true
      stderr.sync = true

      # Start a thread to read output
      output_thread = Thread.new do
        while (line = stdout.gets)
          puts "Test output: #{line}"
          pid = Regexp.last_match(1).to_i if line =~ /Process ID: (\d+)/
        end
      end

      # Wait for the PID to be captured - max 5 seconds
      begin
        Timeout.timeout(5) do
          sleep(0.1) until pid
        end
      rescue Timeout::Error
        # If we can't get the PID within 5 seconds, something is wrong
        raise "Failed to retrieve process ID from test script"
      ensure
        # Stop the output thread if it's still running
        output_thread.kill if output_thread.alive?
      end

      # Make sure we got a valid PID
      expect(pid).not_to be_nil
      expect(pid).to be > 0

      puts "Created test process with PID: #{pid}"

      # Give the process a moment to start the workers
      sleep(1)

      # Send SIGINT to the process
      puts "Sending SIGINT to test process"
      Process.kill("INT", pid)

      # Process should exit within 3 seconds (not 10)
      begin
        Timeout.timeout(3) do
          exit_status = wait_thread.value
          expect(exit_status.success?).to be_falsy # Should exit with non-zero status due to INT signal
        end
      rescue Timeout::Error
        # If it doesn't exit within 3 seconds, kill it and fail the test
        puts "Process did not exit within timeout period - killing it"
        Process.kill("KILL", pid)
        raise "Process did not exit within 3 seconds after SIGINT signal"
      ensure
        # Clean up
        stdin.close unless stdin.closed?
        stdout.close unless stdout.closed?
        stderr.close unless stderr.closed?
      end
    end
  end
end
