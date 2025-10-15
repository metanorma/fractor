#!/usr/bin/env ruby
# frozen_string_literal: true

require 'socket'
require 'json'
require 'time'
require_relative 'chat_common'

# Refactored Chat Server using new Fractor primitives
puts 'Starting Fractor-based chat server (refactored)...'

# Parse command line args
port = ARGV[0]&.to_i || 3000
log_file_path = ARGV[1] || 'logs/server_messages.log'

# Thread-safe hash for client connections
clients = {}
clients_mutex = Mutex.new

# Create server socket
server = TCPServer.new('0.0.0.0', port)

# Set up work queue and Fractor server
work_queue = Fractor::WorkQueue.new

fractor_server = Fractor::ContinuousServer.new(
  worker_pools: [
    { worker_class: ContinuousChatFractor::ChatWorker, num_workers: 2 }
  ],
  work_queue: work_queue,
  log_file: log_file_path
)

# Handle results from Fractor workers
fractor_server.on_result do |result|
  action_data = result.result
  case action_data[:action]
  when :broadcast
    puts "Broadcasting: #{action_data[:content]}"
  when :direct_message
    puts "DM from #{action_data[:from]} to #{action_data[:to]}"
  when :server_message
    puts "Server: #{action_data[:message]}"
  end
end

fractor_server.on_error do |error|
  puts "Error: #{error.error}"
end

# Start Fractor server in background
Thread.new { fractor_server.run }
sleep(0.2) # Give it time to start

puts "Server started on port #{port}"
puts "Server ready to accept connections"

# Handle new client connections
begin
  sockets = [server]

  loop do
    readable, = IO.select(sockets, [], [], 0.1)
    next unless readable

    readable.each do |socket|
      if socket == server
        # New client connection
        client = server.accept
        sockets << client

        # Read join message
        line = client.gets&.chomp
        if line
          message = JSON.parse(line)
          if message['type'] == 'join' && message['data']['username']
            username = message['data']['username']
            clients_mutex.synchronize { clients[username] = client }

            packet = ContinuousChat::MessagePacket.new(
              :server_message,
              { message: "#{username} joined!" }
            )
            work_queue << ContinuousChatFractor::ChatMessage.new(packet)

            client.puts(JSON.generate({
              type: 'server_message',
              data: { message: "Welcome #{username}!" },
              timestamp: Time.now.to_i
            }))
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
            packet = ContinuousChat::MessagePacket.new(
              :server_message,
              { message: "#{username} left" }
            )
            work_queue << ContinuousChatFractor::ChatMessage.new(packet)
          end
          sockets.delete(socket)
          socket.close rescue nil
        else
          # Process message
          message = JSON.parse(line)
          username = clients_mutex.synchronize { clients.key(socket) }

          if message['type'] == 'message'
            content = message['data']['content']
            recipient = message['data']['recipient'] || 'all'

            if recipient == 'all'
              packet = ContinuousChat::MessagePacket.new(
                :broadcast,
                { from: username, content: content }
              )
              work_queue << ContinuousChatFractor::ChatMessage.new(packet)

              # Broadcast to clients
              broadcast_msg = {
                type: 'broadcast',
                data: { from: username, content: content },
                timestamp: Time.now.to_i
              }
              clients_mutex.synchronize do
                clients.each_value { |c| c.puts(JSON.generate(broadcast_msg)) rescue nil }
              end
            else
              packet = ContinuousChat::MessagePacket.new(
                :direct_message,
                { from: username, to: recipient, content: content }
              )
              work_queue << ContinuousChatFractor::ChatMessage.new(packet)

              # Send direct message
              dm_msg = {
                type: 'direct_message',
                data: { from: username, content: content },
                timestamp: Time.now.to_i
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
  puts "\nServer interrupted, shutting down..."
ensure
  fractor_server.stop
  clients_mutex.synchronize { clients.each_value { |c| c.close rescue nil } }
  server&.close
  puts 'Server stopped'
end
