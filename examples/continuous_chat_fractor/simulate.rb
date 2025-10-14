#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'optparse'
require 'json'

module ContinuousChat
  # Simulation controller that manages the server and clients
  class Simulation
    attr_reader :server_port, :log_dir

    def initialize(server_port = 3000, duration = 10, log_dir = 'logs')
      @server_port = server_port
      @duration = duration
      @log_dir = log_dir
      @server_pid = nil
      @client_pids = {}
      @running = false

      # Create log directory if it doesn't exist
      FileUtils.mkdir_p(@log_dir)
    end

    # Start the simulation
    def start
      puts "Starting chat simulation on port #{@server_port}"
      puts "Logs will be saved to #{@log_dir}"

      # Start the server
      start_server

      # Give the server time to initialize
      puts 'Waiting for server to initialize...'
      sleep(2)

      # Start the clients
      start_clients

      @running = true
      puts 'Chat simulation started'

      # Wait for the specified duration
      puts "Simulation will run for #{@duration} seconds"

      # Give clients time to connect
      sleep(2)
      puts 'Clients should be connecting now...'

      # Wait for messages to be processed
      remaining_time = @duration - 4
      if remaining_time.positive?
        puts "Waiting #{remaining_time} more seconds for processing..."
        sleep(remaining_time)
      end

      puts 'Simulation time complete, stopping...'

      # Stop the simulation
      stop

      # Analyze the logs
      analyze_logs

      true
    rescue StandardError => e
      puts "Failed to start simulation: #{e.message}"
      stop
      false
    end

    # Stop the simulation
    def stop
      puts 'Stopping chat simulation...'

      # Stop all clients
      stop_clients

      # Stop the server
      stop_server

      @running = false
      puts 'Chat simulation stopped'
    end

    private

    # Start the server process
    def start_server
      server_log_file = File.join(@log_dir, 'server_messages.log')

      # Get the directory where this script is located
      script_dir = File.dirname(__FILE__)
      server_script = File.join(script_dir, 'chat_server.rb')

      server_cmd = "ruby #{server_script} #{@server_port} #{server_log_file}"

      puts "Starting server: #{server_cmd}"

      # Start the server process as a fork
      @server_pid = fork do
        exec(server_cmd)
      end

      puts "Server started with PID #{@server_pid}"
    end

    # Stop the server process
    def stop_server
      return unless @server_pid

      puts "Stopping server (PID #{@server_pid})..."

      # Send SIGINT to the server process
      begin
        Process.kill('INT', @server_pid)
        # Give it a moment to shut down gracefully
        sleep(1)

        # Force kill if still running
        Process.kill('KILL', @server_pid) if process_running?(@server_pid)
      rescue Errno::ESRCH
        # Process already gone
      end

      @server_pid = nil
      puts 'Server stopped'
    end

    # Start client processes
    def start_clients
      # Define the client usernames and their messages
      clients = {
        'alice' => [
          { content: 'Hello everyone!', recipient: 'all' },
          { content: "I'm working on a Ruby project using sockets",
            recipient: 'all' },
          { content: "It's a simple chat server and client", recipient: 'all' }
        ],
        'bob' => [
          { content: 'Hi Alice!', recipient: 'alice' },
          { content: 'That sounds interesting. What kind of project?',
            recipient: 'alice' },
          { content: "Cool! I love Ruby's socket features",
            recipient: 'alice' }
        ],
        'charlie' => [
          { content: "How's everyone doing today?", recipient: 'all' },
          { content: 'Are you using any specific libraries?',
            recipient: 'alice' },
          { content: 'Non-blocking IO in chat clients is efficient',
            recipient: 'all' }
        ]
      }

      puts "Starting #{clients.size} clients: #{clients.keys.join(', ')}"

      # Start each client in a separate process
      clients.each do |username, messages|
        start_client(username, messages)
      end
    end

    # Start a single client process
    def start_client(username, messages)
      client_log_file = File.join(@log_dir, "client_#{username}_messages.log")
      messages_file = File.join(@log_dir,
                                "client_#{username}_send_messages.json")

      # Write the messages to a JSON file
      File.write(messages_file, JSON.generate(messages))

      # Get the directory where this script is located
      script_dir = File.dirname(__FILE__)
      client_script = File.join(script_dir, 'chat_client.rb')

      # Build the client command
      client_cmd = "ruby #{client_script} #{username} #{@server_port} #{client_log_file}"

      puts "Starting client #{username}"

      # Start the client process as a fork
      @client_pids[username] = fork do
        exec(client_cmd)
      end

      puts "Client #{username} started with PID #{@client_pids[username]}"
    end

    # Stop all client processes
    def stop_clients
      return if @client_pids.empty?

      puts "Stopping #{@client_pids.size} clients..."

      @client_pids.each do |username, pid|
        # Try to gracefully terminate the process
        begin
          Process.kill('INT', pid)
          # Give it a moment to shut down
          sleep(0.5)

          # Force kill if still running
          Process.kill('KILL', pid) if process_running?(pid)
        rescue Errno::ESRCH
          # Process already gone
        end

        puts "Client #{username} stopped"
      rescue StandardError => e
        puts "Error stopping client #{username}: #{e.message}"
      end

      @client_pids.clear
    end

    # Check if a process is still running
    def process_running?(pid)
      Process.getpgid(pid)
      true
    rescue Errno::ESRCH
      false
    end

    # Analyze the log files after the simulation
    def analyze_logs
      puts "\nSimulation Results"
      puts '================='

      # Analyze server log
      server_log_file = File.join(@log_dir, 'server_messages.log')
      if File.exist?(server_log_file)
        server_log = File.readlines(server_log_file)
        puts "Server processed #{server_log.size} log entries"

        # Count message types
        message_count = server_log.count do |line|
          line.include?('Received from')
        end
        broadcast_count = server_log.count do |line|
          line.include?('Fractor: Broadcasting message from') ||
            line.include?('Fractor processed: broadcast')
        end
        direct_count = server_log.count do |line|
          line.include?('Fractor: Direct message from') ||
            line.include?('Fractor processed: direct_message')
        end

        puts "  - #{message_count} messages received from clients"
        puts "  - #{broadcast_count} broadcast messages processed by Fractor"
        puts "  - #{direct_count} direct messages processed by Fractor"
      else
        puts 'Server log file not found'
      end

      puts "\nClient Activity:"
      # Analyze each client log
      @client_pids.each_key do |username|
        client_log_file = File.join(@log_dir, "client_#{username}_messages.log")
        if File.exist?(client_log_file)
          client_log = File.readlines(client_log_file)
          sent_count = client_log.count { |line| line.include?('Sent message') }
          received_count = client_log.count do |line|
            line.include?('Received:')
          end

          puts "  #{username}: Sent #{sent_count} messages, Received #{received_count} messages"
        else
          puts "  #{username}: Log file not found"
        end
      end

      puts "\nLog files are available in the #{@log_dir} directory for detailed analysis."
    end
  end
end

# When run directly, start the simulation
if __FILE__ == $PROGRAM_NAME
  options = {
    port: 3000,
    duration: 10,
    log_dir: 'logs'
  }

  # Parse command line options
  OptionParser.new do |opts|
    opts.banner = 'Usage: ruby simulate.rb [options]'

    opts.on('-p', '--port PORT', Integer,
            'Server port (default: 3000)') do |port|
      options[:port] = port
    end

    opts.on('-d', '--duration SECONDS', Integer,
            'Simulation duration in seconds (default: 10)') do |duration|
      options[:duration] = duration
    end

    opts.on('-l', '--log-dir DIR',
            'Directory for log files (default: logs)') do |dir|
      options[:log_dir] = dir
    end

    opts.on('-h', '--help', 'Show this help message') do
      puts opts
      exit
    end
  end.parse!

  puts 'Starting Chat Simulation'
  puts '======================'
  puts 'This simulation runs a chat server and multiple clients as separate processes'
  puts 'to demonstrate a basic chat application with socket communication.'
  puts

  # Create and run the simulation
  simulation = ContinuousChat::Simulation.new(
    options[:port],
    options[:duration],
    options[:log_dir]
  )

  # Set up signal handlers to properly clean up child processes
  Signal.trap('INT') do
    puts "\nSimulation interrupted"
    simulation.stop
    exit
  end

  Signal.trap('TERM') do
    puts "\nSimulation terminated"
    simulation.stop
    exit
  end

  begin
    simulation.start
  rescue Interrupt
    puts "\nSimulation interrupted"
    simulation.stop
  end

  puts 'Simulation completed'
end
