#!/usr/bin/env ruby
# frozen_string_literal: true

require "socket"
require "json"
require "time"
require "fileutils"
require_relative "../continuous_chat_common/message_protocol"

# Simple Chat Server using Ruby's standard socket library
# Based on the approach from https://dev.to/aurelieverrot/create-a-chat-in-the-command-line-with-ruby-2po9
# but modified to use JSON for message passing.
puts "Starting chat server..."

# Parse command line args
port = ARGV[0]&.to_i || 3000
log_file_path = ARGV[1] || "logs/server_messages.log"

# Create logs directory if it doesn't exist
FileUtils.mkdir_p(File.dirname(log_file_path))
log_file = File.open(log_file_path, "w")

def log_message(message, log_file)
  timestamp = Time.now.strftime("%Y-%m-%d %H:%M:%S.%L")
  log_entry = "[#{timestamp}] #{message}"

  # Check if log file is still open before writing
  if log_file && !log_file.closed?
    log_file.puts(log_entry)
    log_file.flush # Ensure it's written immediately
  end

  # Also print to console for debugging
  puts log_entry
end

# Create the server socket
server = TCPServer.new("0.0.0.0", port)
log_message("Server started on port #{port}", log_file)
puts "Server bound to port #{port}"

# Array to store connected clients
clients = {}

# Broadcast a message to all clients
def announce_to_everyone(clients, message, log_file)
  log_message("Broadcasting: #{message}", log_file)

  # Convert to JSON if it's not already a string
  message_json = message.is_a?(String) ? message : JSON.generate(message)

  # Create a copy of the clients hash to avoid modification during iteration
  clients_copy = clients.dup

  clients_copy.each do |username, client|
    client.puts(message_json)
  rescue StandardError => e
    log_message("Error broadcasting to #{username}: #{e.message}", log_file)
    # We don't disconnect here, that's handled in the client thread
  end
end

# Handle a new client joining the chat
def handle_new_client(clients, client, log_file)
  line = client.gets&.chomp
  return client.close unless line

  log_message("Received join message: #{line}", log_file)

  # Parse the join message
  message = JSON.parse(line)

  if message["type"] == "join" && message["data"] && message["data"]["username"]
    username = message["data"]["username"]

    # Store the client with username as key
    clients[username] = client

    # Send welcome message to the client
    welcome_msg = {
      type: "server_message",
      data: {
        message: "Hello #{username}! Connected clients: #{clients.count}",
      },
      timestamp: Time.now.to_i,
    }
    client.puts(JSON.generate(welcome_msg))

    # Broadcast to all clients that a new user joined
    join_msg = {
      type: "server_message",
      data: {
        message: "#{username} joined the chat!",
      },
      timestamp: Time.now.to_i,
    }
    announce_to_everyone(clients, join_msg, log_file)

    # Broadcast the updated user list
    user_list_msg = {
      type: "user_list",
      data: {
        users: clients.keys,
      },
      timestamp: Time.now.to_i,
    }
    announce_to_everyone(clients, user_list_msg, log_file)

    true
  else
    # Invalid join message
    error_msg = {
      type: "error",
      data: {
        message: "First message must be a valid join command",
      },
      timestamp: Time.now.to_i,
    }
    client.puts(JSON.generate(error_msg))
    client.close
    false
  end
rescue JSON::ParserError => e
  log_message("Error parsing initial join message: #{e.message}", log_file)
  client.puts(JSON.generate({
                              type: "error",
                              data: {
                                message: "Invalid JSON format in join message",
                              },
                              timestamp: Time.now.to_i,
                            }))
  client.close
  false
rescue StandardError => e
  log_message("Error handling new client: #{e.message}", log_file)
  client.close
  false
end

# Process a message from an existing client
def process_client_message(clients, client, username, log_file)
  # Read a message from the client (non-blocking with timeout)
  readable, = IO.select([client], nil, nil, 0)
  return true unless readable # No data to read yet

  line = client.gets&.chomp
  return false unless line # Client disconnected

  begin
    message = JSON.parse(line)
    log_message("Received from #{username}: #{line}", log_file)

    case message["type"]
    when "message"
      content = message["data"]["content"]
      recipient = message["data"]["recipient"] || "all"

      if content.start_with?("/")
        # Handle commands
        case content
        when "/list"
          list_msg = {
            type: "user_list",
            data: {
              users: clients.keys,
            },
            timestamp: Time.now.to_i,
          }
          client.puts(JSON.generate(list_msg))
        else
          # Unknown command
          client.puts(JSON.generate({
                                      type: "error",
                                      data: {
                                        message: "Unknown command: #{content}",
                                      },
                                      timestamp: Time.now.to_i,
                                    }))
        end
      elsif recipient == "all"
        # Broadcast message
        broadcast_msg = {
          type: "broadcast",
          data: {
            from: username,
            content: content,
          },
          timestamp: Time.now.to_i,
        }
        announce_to_everyone(clients, broadcast_msg, log_file)
      elsif clients[recipient]
        # Direct message
        dm_msg = {
          type: "direct_message",
          data: {
            from: username,
            content: content,
          },
          timestamp: Time.now.to_i,
        }
        clients[recipient].puts(JSON.generate(dm_msg))
        # Also send to sender if not the same person
        client.puts(JSON.generate(dm_msg)) if username != recipient
      else
        # Recipient not found
        client.puts(JSON.generate({
                                    type: "error",
                                    data: {
                                      message: "User #{recipient} not found",
                                    },
                                    timestamp: Time.now.to_i,
                                  }))
      end
    when "leave"
      # Client wants to leave
      return false
    end
  rescue JSON::ParserError => e
    log_message("Error parsing JSON from #{username}: #{e.message}", log_file)
    client.puts(JSON.generate({
                                type: "error",
                                data: {
                                  message: "Invalid JSON format",
                                },
                                timestamp: Time.now.to_i,
                              }))
  rescue StandardError => e
    log_message("Error processing message from #{username}: #{e.message}",
                log_file)
    return false
  end

  true # Client still connected
end

# Handle client disconnection
def handle_client_disconnect(clients, client, log_file)
  username = clients.key(client)
  return unless username

  # Remove from clients list
  clients.delete(username)
  log_message("Client disconnected: #{username}", log_file)

  # Notify everyone
  leave_msg = {
    type: "server_message",
    data: {
      message: "#{username} left the chat.",
    },
    timestamp: Time.now.to_i,
  }
  announce_to_everyone(clients, leave_msg, log_file)

  # Update user list
  user_list_msg = {
    type: "user_list",
    data: {
      users: clients.keys,
    },
    timestamp: Time.now.to_i,
  }
  announce_to_everyone(clients, user_list_msg, log_file)

  # Close the client socket
  begin
    client.close
  rescue StandardError
    nil
  end
end

# Main server loop
begin
  log_message("Server ready to accept connections", log_file)

  # Add the server socket to the list of sockets to monitor
  sockets = [server]

  # Main event loop
  loop do
    # Use IO.select to check which sockets have data to read
    # This is non-blocking and allows us to handle multiple clients sequentially
    readable, _, errored = IO.select(sockets, [], sockets, 0.1)

    # Handle errors first
    if errored && !errored.empty?
      errored.each do |socket|
        raise "Server socket error" if socket == server

        # Server socket error - critical

        # Client socket error
        username = clients.key(socket)
        log_message("Error on client socket: #{username || 'unknown'}",
                    log_file)
        handle_client_disconnect(clients, socket, log_file)
        sockets.delete(socket)
      end
    end

    # Nothing to process this iteration
    next unless readable

    # Process readable sockets
    readable.each do |socket|
      if socket == server
        # New client connection
        begin
          client = server.accept
          log_message(
            "New client connection from #{client.peeraddr[2]}:#{client.peeraddr[1]}", log_file
          )

          # Add the client socket to our monitoring list
          sockets << client

          # We'll process the initial join message in the next iteration
        rescue StandardError => e
          log_message("Error accepting client: #{e.message}", log_file)
        end
      elsif clients.key(socket)
        # Existing client sent data
        username = clients.key(socket)

        # Process message, remove client if it disconnected
        unless process_client_message(clients, socket, username, log_file)
          handle_client_disconnect(clients, socket, log_file)
          sockets.delete(socket)
        end
      else
        # This is a new client that needs to send their join message
        unless handle_new_client(clients, socket, log_file)
          # Join failed, remove from sockets
          sockets.delete(socket)
        end
      end
    end
  end
rescue Interrupt
  log_message("Server interrupted, shutting down...", log_file)
rescue StandardError => e
  log_message("Server error: #{e.message}", log_file)
ensure
  # Close all client connections
  clients.each_value do |client|
    client.close
  rescue StandardError
    # Ignore errors when closing
  end

  # Close the server socket
  server&.close

  # Close the log file
  log_file&.close

  log_message("Server stopped", log_file)
end
