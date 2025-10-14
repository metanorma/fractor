#!/usr/bin/env ruby
# frozen_string_literal: true

require "socket"
require "json"
require "time"
require "fileutils"
require "thread"
require_relative "chat_common"

# Simplified Chat Server using Fractor in continuous mode
puts "Starting Fractor-based chat server..."

# Parse command line args
port = ARGV[0]&.to_i || 3000
log_file_path = ARGV[1] || "logs/server_messages.log"

# Create logs directory if it doesn't exist
FileUtils.mkdir_p(File.dirname(log_file_path))
log_file = File.open(log_file_path, "w")

def log_message(message, log_file)
  timestamp = Time.now.strftime("%Y-%m-%d %H:%M:%S.%L")
  log_entry = "[#{timestamp}] #{message}"

  if log_file && !log_file.closed?
    log_file.puts(log_entry)
    log_file.flush
  end

  puts log_entry
end

# Thread-safe queue for messages from clients
message_queue = Queue.new

# Thread-safe hash for client connections
clients = {}
clients_mutex = Mutex.new

# Create the server socket
server = TCPServer.new("0.0.0.0", port)
log_message("Server started on port #{port}", log_file)

# Set up Fractor supervisor in continuous mode
supervisor = Fractor::Supervisor.new(
  worker_pools: [
    { worker_class: ContinuousChatFractor::ChatWorker, num_workers: 2 },
  ],
  continuous_mode: true,
)

# Register work source that pulls from the message queue
supervisor.register_work_source do
  messages = []
  # Pull up to 5 messages from the queue at once
  5.times do
    break if message_queue.empty?

    msg = message_queue.pop(true) rescue nil
    messages << msg if msg
  end
  messages.empty? ? nil : messages
end

# Start supervisor in a background thread
supervisor_thread = Thread.new do
  supervisor.run
rescue StandardError => e
  log_message("Supervisor error: #{e.message}", log_file)
  log_message(e.backtrace.join("\n"), log_file)
end

log_message("Fractor supervisor started with 2 workers", log_file)
log_message("Server ready to accept connections", log_file)

# Process results from Fractor workers in a background thread
results_thread = Thread.new do
  log_message("Results processing thread started", log_file)
  loop do
    sleep(0.05) # Check more frequently

    # Process completed work results
    results_count = 0
    loop do
      result = supervisor.results.results.shift
      break unless result

      results_count += 1
      action_data = result.result
      log_message("Fractor processed: #{action_data[:action]}", log_file)

      case action_data[:action]
      when :broadcast
        log_message(
          "Fractor: Broadcasting message from #{action_data[:from]}: #{action_data[:content]}",
          log_file,
        )
      when :direct_message
        log_message(
          "Fractor: Direct message from #{action_data[:from]} to #{action_data[:to]}: #{action_data[:content]}",
          log_file,
        )
      when :server_message
        log_message("Fractor: Server message: #{action_data[:message]}", log_file)
      end
    end

    # Process errors
    errors_count = 0
    loop do
      error_result = supervisor.results.errors.shift
      break unless error_result

      errors_count += 1
      log_message("Fractor error: #{error_result.error}", log_file)
    end

    # Log activity if we processed anything
    if results_count > 0 || errors_count > 0
      log_message("Fractor processed #{results_count} results, #{errors_count} errors this cycle", log_file)
    end
  end
rescue StandardError => e
  log_message("Results thread error: #{e.message}", log_file)
  log_message(e.backtrace.join("\n"), log_file)
end

# Handle new client connections in a simple loop
begin
  sockets = [server]

  loop do
    readable, = IO.select(sockets, [], [], 0.1)
    next unless readable

    readable.each do |socket|
      if socket == server
        # New client connection
        client = server.accept
        log_message("New client from #{client.peeraddr[2]}:#{client.peeraddr[1]}", log_file)
        sockets << client

        # Read join message
        line = client.gets&.chomp
        if line
          message = JSON.parse(line)
          if message["type"] == "join" && message["data"]["username"]
            username = message["data"]["username"]
            clients_mutex.synchronize { clients[username] = client }

            # Add join message to Fractor queue
            packet = ContinuousChat::MessagePacket.new(
              :server_message,
              { message: "#{username} joined!" },
            )
            message_queue << ContinuousChatFractor::ChatMessage.new(packet)

            # Send welcome
            client.puts(JSON.generate({
              type: "server_message",
              data: { message: "Welcome #{username}!" },
              timestamp: Time.now.to_i,
            }))

            log_message("Client #{username} joined", log_file)
          end
        end
      else
        # Existing client sent data
        line = socket.gets&.chomp
        if line.nil?
          # Client disconnected
          username = clients_mutex.synchronize { clients.key(socket) }
          if username
            clients_mutex.synchronize { clients.delete(username) }
            log_message("Client #{username} disconnected", log_file)

            # Add disconnect message to Fractor queue
            packet = ContinuousChat::MessagePacket.new(
              :server_message,
              { message: "#{username} left" },
            )
            message_queue << ContinuousChatFractor::ChatMessage.new(packet)
          end
          sockets.delete(socket)
          socket.close rescue nil
        else
          # Process message
          message = JSON.parse(line)
          username = clients_mutex.synchronize { clients.key(socket) }

          case message["type"]
          when "message"
            content = message["data"]["content"]
            recipient = message["data"]["recipient"] || "all"

            log_message("Received from #{username}: #{content}", log_file)

            if recipient == "all"
              # Create broadcast work item
              packet = ContinuousChat::MessagePacket.new(
                :broadcast,
                { from: username, content: content },
              )
              message_queue << ContinuousChatFractor::ChatMessage.new(packet)

              # Actually broadcast to clients
              broadcast_msg = {
                type: "broadcast",
                data: { from: username, content: content },
                timestamp: Time.now.to_i,
              }
              clients_mutex.synchronize do
                clients.each_value do |c|
                  c.puts(JSON.generate(broadcast_msg)) rescue nil
                end
              end
            else
              # Create direct message work item
              packet = ContinuousChat::MessagePacket.new(
                :direct_message,
                { from: username, to: recipient, content: content },
              )
              message_queue << ContinuousChatFractor::ChatMessage.new(packet)

              # Actually send direct message
              dm_msg = {
                type: "direct_message",
                data: { from: username, content: content },
                timestamp: Time.now.to_i,
              }
              clients_mutex.synchronize do
                recipient_socket = clients[recipient]
                if recipient_socket
                  recipient_socket.puts(JSON.generate(dm_msg)) rescue nil
                  socket.puts(JSON.generate(dm_msg)) if username != recipient
                end
              end
            end
          end
        end
      end
    end
  end
rescue Interrupt
  log_message("Server interrupted, shutting down...", log_file)
ensure
  # Stop the Fractor supervisor
  supervisor.stop
  supervisor_thread.join(2)

  # Close all client connections
  clients_mutex.synchronize do
    clients.each_value { |c| c.close rescue nil }
  end

  server&.close
  log_file&.close

  log_message("Server stopped", log_file)
end
