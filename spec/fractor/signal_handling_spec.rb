# frozen_string_literal: true

require "spec_helper"
require "open3"
require "timeout"

RSpec.describe "Signal handling in Fractor" do
  # Path to our test fixture
  let(:fixture_script) do
    File.join(File.dirname(__FILE__), "..", "fixtures",
              "long_running_fractor.rb")
  end

  # Helper method to spawn test process and capture PID
  # rubocop:disable Metrics/AbcSize
  def spawn_test_process(fixture_script)
    pid = nil
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

    [pid, stdin, stdout, stderr, wait_thread]
  end
  # rubocop:enable Metrics/AbcSize

  # Helper method to cleanup test process
  def cleanup_process(pid, stdin, stdout, stderr, force: false)
    force_kill_process(pid) if force && pid
    close_streams(stdin, stdout, stderr)
  end

  # rubocop:disable Metrics/AbcSize
  def force_kill_process(pid)
    if Gem.win_platform?
      system("taskkill /F /PID #{pid} 2>nul")
    else
      begin
        Process.kill("KILL", pid)
      rescue StandardError
        nil
      end
    end
  rescue StandardError
    nil
  end
  # rubocop:enable Metrics/AbcSize

  def close_streams(stdin, stdout, stderr)
    stdin.close unless stdin.closed?
    stdout.close unless stdout.closed?
    stderr.close unless stderr.closed?
  end

  context "when on Unix-like systems", unless: Gem.win_platform? do
    describe "Ctrl+C (SIGINT) handling" do
      it "properly terminates when receiving a SIGINT signal" do
        pid, stdin, stdout, stderr, wait_thread = spawn_test_process(fixture_script)

        # Send SIGINT signal to the process
        puts "Sending SIGINT to test process"
        Process.kill("INT", pid)

        # Process should exit within 3 seconds
        begin
          Timeout.timeout(3) do
            exit_status = wait_thread.value
            expect(exit_status).not_to be_success # Should exit with non-zero status due to INT signal
          end
        rescue Timeout::Error
          # If it doesn't exit within 3 seconds, kill it and fail the test
          puts "Process did not exit within timeout period - killing it"
          cleanup_process(pid, stdin, stdout, stderr, force: true)
          raise "Process did not exit within 3 seconds after SIGINT signal"
        ensure
          cleanup_process(pid, stdin, stdout, stderr)
        end
      end
    end
  end

  context "when on Windows", if: Gem.win_platform? do
    describe "Ctrl+Break (SIGBREAK) handling" do
      it "properly terminates when receiving a SIGBREAK signal" do
        pid, stdin, stdout, stderr, wait_thread = spawn_test_process(fixture_script)

        # Send SIGBREAK signal to the process
        # On Windows, SIGBREAK is more reliable than SIGINT for termination
        puts "Sending SIGBREAK to test process"
        begin
          Process.kill("BREAK", pid)
        rescue ArgumentError, Errno::EINVAL
          # If BREAK doesn't work, skip this test
          cleanup_process(pid, stdin, stdout, stderr, force: true)
          skip "SIGBREAK not supported on this Ruby version"
        end

        # Process should exit within 5 seconds (Windows may be slower)
        begin
          Timeout.timeout(5) do
            exit_status = wait_thread.value
            # On Windows, the exit status may differ, so we just verify it exits
            expect(exit_status.exited?).to be true
          end
        rescue Timeout::Error
          # If it doesn't exit within 5 seconds, kill it and fail the test
          puts "Process did not exit within timeout period - killing it"
          cleanup_process(pid, stdin, stdout, stderr, force: true)
          raise "Process did not exit within 5 seconds after SIGBREAK signal"
        ensure
          cleanup_process(pid, stdin, stdout, stderr)
        end
      end
    end

    describe "Forced termination (taskkill) handling" do
      it "can be forcefully terminated with taskkill" do
        pid, stdin, stdout, stderr, wait_thread = spawn_test_process(fixture_script)

        # Use taskkill to forcefully terminate
        puts "Using taskkill to forcefully terminate Windows process"
        system("taskkill /F /PID #{pid} >nul 2>&1")

        # Process should exit within 2 seconds when forcefully killed
        begin
          Timeout.timeout(2) do
            exit_status = wait_thread.value
            # Forceful termination, just verify it exits
            expect(exit_status.exited?).to be true
          end
        rescue Timeout::Error
          # This shouldn't happen with /F flag, but handle it anyway
          puts "Process did not exit within timeout period after taskkill"
          cleanup_process(pid, stdin, stdout, stderr, force: true)
          raise "Process did not exit within 2 seconds after taskkill /F"
        ensure
          cleanup_process(pid, stdin, stdout, stderr)
        end
      end
    end
  end
end
