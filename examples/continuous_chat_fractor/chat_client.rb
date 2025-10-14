#!/usr/bin/env ruby
# frozen_string_literal: true

require 'socket'
require 'json'
require 'fileutils'

module ContinuousChat
  # Simple Chat Client using Ruby's standard socket library
  class ChatClient
    def initialize(username, server_host = 'localhost', server_port = 3000,
                   log_file_path = nil)
      @username = username
      @server_host = server_host
      @server_port = server_port
      @running = true

      # Set up logging
      @log_file_path = log_file_path || "logs/client_#{username}_messages.log"
      FileUtils.mkdir_p(File.dirname(@log_file_path))
      @log_file = File.open(@log_file_path, 'w')

      log_message("Client initialized for #{username}, connecting to #{server_host}:#{server_port}")
    end

    def connect
      puts "Connecting to server at #{@server_host}:#{@server_port}..."
      log_message("Connecting to server at #{@server_host}:#{@server_port}")

      begin
        @socket = TCPSocket.new(@server_host, @server_port)

        # Send join message
        join_data = {
          type: 'join',
          data: {
            username: @username
          },
          timestamp: Time.now.to_i
        }
        @socket.puts(JSON.generate(join_data))
        log_message("Sent join message: #{join_data}")

        puts 'Connected to chat server!'
        log_message('Connected to chat server')

        true
      rescue StandardError => e
        puts "Failed to connect: #{e.message}"
        log_message("Failed to connect: #{e.message}")
        false
      end
    end

    def start
      return false unless @socket

      # Main event loop that handles both sending and receiving messages
      # without creating separate threads
      main_event_loop

      true
    end

    # Main event loop that handles both user input and server messages
    def main_event_loop
      log_message('Starting main event loop')

      # Print initial prompt
      print "(#{@username})> "
      $stdout.flush

      while @running
        # Use IO.select to wait for input from either STDIN or the socket
        # This is non-blocking and allows us to handle both in a single loop
        readable, = IO.select([@socket, $stdin], nil, nil, 0.1)

        next unless readable # Nothing to process this iteration

        readable.each do |io|
          if io == $stdin
            # Handle user input
            handle_user_input
          elsif io == @socket
            # Handle server message
            handle_server_message
          end
        end
      end
    rescue Interrupt
      log_message('Client interrupted')
      @running = false
    rescue StandardError => e
      log_message("Error in main event loop: #{e.message}")
      @running = false
    ensure
      disconnect
    end

    # Handle user input (non-blocking)
    def handle_user_input
      text = $stdin.gets&.chomp
      return unless text

      # Check if client wants to quit
      if text == '/quit' || text.nil?
        @running = false
        return
      end

      # Create message packet
      message_data = {
        type: 'message',
        data: {
          content: text,
          recipient: 'all' # Default to broadcast
        },
        timestamp: Time.now.to_i
      }

      # Send to server
      @socket.puts(JSON.generate(message_data))
      log_message("Sent message: #{text}")

      # Print prompt for next input
      print "(#{@username})> "
      $stdout.flush
    rescue StandardError => e
      log_message("Error handling user input: #{e.message}")
      @running = false
    end

    # Handle server message (non-blocking)
    def handle_server_message
      line = @socket.gets&.chomp

      if line.nil?
        # Server closed the connection
        log_message('Connection to server lost')
        @running = false
        return
      end

      # Parse and handle the message
      message = JSON.parse(line)
      log_message("Received: #{line}")

      # Display formatted message based on type
      case message['type']
      when 'broadcast'
        puts "\r#{message['data']['from']}: #{message['data']['content']}"
      when 'direct_message'
        puts "\r[DM] #{message['data']['from']}: #{message['data']['content']}"
      when 'server_message'
        puts "\r[Server] #{message['data']['message']}"
      when 'user_list'
        puts "\r[Server] Users online: #{message['data']['users'].join(', ')}"
      when 'error'
        puts "\r[Error] #{message['data']['message']}"
      end

      # Reprint the prompt
      print "(#{@username})> "
      $stdout.flush
    rescue StandardError => e
      log_message("Error handling server message: #{e.message}")
      # Don't immediately break for connection errors, may be temporary
      # Just log and continue, IO.select will catch closed connections
    end

    def run_with_messages(messages, _delay_between_messages = 1)
      return false unless @socket && @running

      log_message("Running with #{messages.size} predefined messages")
      puts "Sending #{messages.size} predefined messages"

      # Send all messages in a non-blocking way
      batch_send_messages(messages)

      log_message('Finished sending all predefined messages')

      # Start the event loop to receive responses
      main_event_loop

      true
    end

    # Helper to send a batch of messages without blocking
    def batch_send_messages(messages)
      messages.each_with_index do |msg, index|
        content = msg[:content]
        recipient = msg[:recipient] || 'all'

        log_message("Sending message #{index + 1}: '#{content}' to #{recipient}")

        message_data = {
          type: 'message',
          data: {
            content: content,
            recipient: recipient
          },
          timestamp: Time.now.to_i
        }

        @socket.puts(JSON.generate(message_data))
        log_message("Sent message to #{recipient}: #{content}")

        # Small delay between messages for stability
        sleep(0.1)
      end
    end

    def disconnect
      return unless @running

      @running = false
      log_message('Disconnecting from server')

      if @socket && !@socket.closed?
        # Send leave message
        leave_data = {
          type: 'leave',
          data: {
            username: @username
          },
          timestamp: Time.now.to_i
        }
        @socket.puts(JSON.generate(leave_data))
        log_message('Sent leave message')

        @socket.close
      end

      @log_file&.close

      puts 'Disconnected from server.'
      true
    end

    private

    def log_message(message)
      timestamp = Time.now.strftime('%Y-%m-%d %H:%M:%S.%L')
      log_entry = "[#{timestamp}] #{message}"

      @log_file.puts(log_entry)
      @log_file.flush # Ensure it's written immediately
    end
  end
end

# When run directly, start the client
if __FILE__ == $PROGRAM_NAME
  require 'fileutils'
  require 'json'

  puts 'Chat Client'
  puts '==========='
  puts 'This is the chat client that connects to the chat server.'
  puts 'All messages are logged to a file for later analysis.'
  puts

  # Get username from command line or prompt
  username = ARGV[0]

  unless username
    print 'Enter your username: '
    username = gets.chomp
  end

  # Get port from command line or use default
  port = ARGV[1]&.to_i || 3000
  log_file = ARGV[2] || "logs/client_#{username}_messages.log"

  # Check for messages file
  messages_file = "logs/client_#{username}_send_messages.json"

  # Create and run the client
  client = ContinuousChat::ChatClient.new(username, 'localhost', port, log_file)

  if client.connect
    begin
      # Load and send messages if the file exists
      if File.exist?(messages_file)
        puts "Loading messages from #{messages_file}"
        messages = JSON.parse(File.read(messages_file), symbolize_names: true)
        puts "Loaded #{messages.size} messages"

        # Send the messages
        client.run_with_messages(messages)
      end

      # Start the client
      client.start
    rescue Interrupt
      puts "\nClient interrupted."
    ensure
      client.disconnect
    end
  end

  puts 'Chat client exited.'
end
