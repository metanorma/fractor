# frozen_string_literal: true

module Fractor
  # Handles signal management for graceful shutdown.
  # Extracted from Supervisor to follow Single Responsibility Principle.
  #
  # Note: The ShutdownSignal exception class is defined in supervisor.rb
  # to maintain backwards compatibility.
  class SignalHandler
    def initialize(continuous_mode: false, debug: false, status_callback: nil, shutdown_callback: nil)
      @continuous_mode = continuous_mode
      @debug = debug
      @status_callback = status_callback
      @shutdown_callback = shutdown_callback
    end

    # Set up signal handlers for graceful shutdown
    # Handles SIGINT (Ctrl+C), SIGTERM (systemd/docker), and platform-specific status signals
    def setup
      setup_universal_signals
      setup_status_signal
    end

    private

    def setup_universal_signals
      # Universal signals (work on all platforms)
      Signal.trap("INT") { handle_shutdown("SIGINT") }
      Signal.trap("TERM") { handle_shutdown("SIGTERM") }
    end

    def setup_status_signal
      if Gem.win_platform?
        setup_windows_status_signal
      else
        setup_unix_status_signal
      end
    end

    def setup_windows_status_signal
      # Windows: Try SIGBREAK (Ctrl+Break) if available
      begin
        Signal.trap("BREAK") { trigger_status_callback }
      rescue ArgumentError
        # SIGBREAK not supported on this Ruby version/platform
        # Status monitoring unavailable on Windows
      end
    end

    def setup_unix_status_signal
      # Unix/Linux/macOS: Use SIGUSR1
      begin
        Signal.trap("USR1") { trigger_status_callback }
      rescue ArgumentError
        # SIGUSR1 not supported on this platform
      end
    end

    def handle_shutdown(signal_name)
      if @continuous_mode
        log_debug "\n#{signal_name} received. Initiating graceful shutdown..."
        @shutdown_callback&.call(:graceful)
      else
        log_debug "\n#{signal_name} received. Initiating immediate shutdown..."
        Thread.current.raise(ShutdownSignal, "Interrupted by #{signal_name}")
      end
    rescue Exception => e
      log_debug "Error in signal handler: #{e.class}: #{e.message}"
      log_debug e.backtrace.join("\n") if @debug
      exit!(1)
    end

    def trigger_status_callback
      @status_callback&.call
    end

    def log_debug(message)
      puts message if @debug
    end
  end
end
