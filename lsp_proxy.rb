#!/usr/bin/env ruby
require "socket"
require "json"
require "io/console"

# A persistent LSP proxy that maintains one connection to Solargraph,
# intercepts duplicate initialize calls, and (using IO.select) gracefully
# handles client disconnects by returning to a listening state.
class LSPProxy
  def initialize(solargraph_host, solargraph_port, listen_port)
    @solargraph_host = solargraph_host
    @solargraph_port = solargraph_port
    @listen_port     = listen_port

    # Establish a persistent connection to Solargraph.
    @sg_socket = TCPSocket.new(@solargraph_host, @solargraph_port)
    @sg_socket.set_encoding("BINARY")
    puts "Connected persistently to Solargraph at #{@solargraph_host}:#{@solargraph_port}"

    # Variables for caching the handshake.
    @initialized = false
    @cached_initialize_response = nil

    # Start listening for client connections.
    start_client_listener
  end

  # read_message reads a full LSP JSON-RPC message (headers and body) from the given IO.
  # If the connection has closed or no header is received, it returns nil.
  def read_message(io)
    header = ""
    begin
      # Read header lines until a blank line is reached.
      while (line = io.gets)
        break if line == "\r\n"
        header << line
      end
    rescue => e
      puts "Error reading header: #{e}"
      return nil
    end

    # If the header is empty, assume the connection was closed.
    return nil if header.strip.empty?

    if header =~ /Content-Length: (\d+)/
      length = Regexp.last_match(1).to_i
      begin
        body = io.read(length)
      rescue => e
        puts "Error reading body: #{e}"
        return nil
      end
      return nil if body.nil? || body.empty?
      JSON.parse(body)
    else
      puts "Invalid header received: #{header.inspect}"
      nil
    end
  end

  # send_message writes a Hash as an LSP message (with proper headers) to the given IO.
  def send_message(io, msg)
    data = JSON.generate(msg)
    full_message = "Content-Length: #{data.bytesize}\r\n\r\n#{data}"
    io.write(full_message)
  end

  # drain_solargraph_buffer drains any pending messages from the persistent Solargraph socket.
  # This prevents leftover messages from a prior session from interfering with a new handshake.
  def drain_solargraph_buffer
    loop do
      ready = IO.select([@sg_socket], nil, nil, 0)
      break if ready.nil? || ready[0].empty?
      begin
        msg = read_message(@sg_socket)
        break if msg.nil?  # no complete message available
        puts "Draining obsolete Solargraph message: #{msg.inspect}"
      rescue => e
        puts "Error during draining: #{e}"
        break
      end
    end
  end

  # start_client_listener loops forever accepting new client connections.
  def start_client_listener
    server = TCPServer.new(@listen_port)
    puts "Proxy is listening for client connections on port #{@listen_port}"
    loop do
      begin
        client = server.accept
        Thread.new { handle_client(client) }
      rescue => e
        puts "Error accepting client connection: #{e}"
      end
    end
  end

  # handle_client processes one client connection.
  # It first drains the solargraph socket, then handles the handshake (either forwarding
  # a new initialize request or returning a cached response), then enters a bidirectional
  # IO.select loop to forward messages.
  def handle_client(client)
    client.set_encoding("BINARY")
    puts "\nClient connected from #{client.peeraddr[2]}"

    # Drain any pending data from Solargraph before beginning a new session.
    drain_solargraph_buffer

    # Process handshake from client.
    handshake = read_message(client)
    unless handshake
      puts "Client disconnected before sending handshake."
      client.close rescue nil
      return
    end

    if handshake["method"] == "initialize"
      if !@initialized
        puts "Forwarding first initialize handshake to Solargraph..."
        send_message(@sg_socket, handshake)
        response = read_message(@sg_socket)
        unless response
          puts "No handshake response from Solargraph; disconnecting client."
          client.close rescue nil
          return
        end
        # Cache and mark as initialized.
        @cached_initialize_response = response.dup
        @initialized = true
        # Adjust the id to match the client's request.
        response["id"] = handshake["id"]
        send_message(client, response)
        puts "Handshake completed and cached from Solargraph."
      else
        # Already initialized; return the cached handshake.
        puts "Intercepting duplicate initialize handshake; using cached response."
        cached = @cached_initialize_response.dup
        cached["id"] = handshake["id"]
        send_message(client, cached)
      end
    else
      # (If the very first message isn’t "initialize", simply forward it.)
      puts "First message was not initialize; forwarding as-is."
      send_message(@sg_socket, handshake)
      response = read_message(@sg_socket)
      send_message(client, response) if response
    end

    # (Optionally) Forward an "initialized" notification from client.
    if IO.select([client], nil, nil, 0.2)
      notif = read_message(client)
      send_message(@sg_socket, notif) if notif
    end

    puts "Entering main forwarding loop for the client session."
    # Forward messages bidirectionally using IO.select.
    loop do
      ready = IO.select([client, @sg_socket], nil, nil, 5)
      # If no socket is ready, just continue the loop.
      next if ready.nil?

      readers = ready[0]

      # If the client has sent a message, forward it to Solargraph.
      if readers.include?(client)
        msg = read_message(client)
        if msg.nil?
          puts "Client disconnected (read returned nil)."
          break
        end
        begin
          send_message(@sg_socket, msg)
        rescue => e
          puts "Error sending message from client to Solargraph: #{e}"
          break
        end
      end

      # If Solargraph has sent a message, forward it to the client.
      if readers.include?(@sg_socket)
        msg = read_message(@sg_socket)
        if msg.nil?
          puts "Solargraph connection closed unexpectedly."
          break
        end
        begin
          send_message(client, msg)
        rescue => e
          puts "Error sending message from Solargraph to client: #{e}"
          break
        end
      end
    end

    client.close rescue nil
    puts "Client session ended. Returning to listening state."
  rescue => e
    puts "Error in handle_client: #{e}"
    client.close rescue nil
  end
end

if __FILE__ == $PROGRAM_NAME
  solargraph_host = "localhost"
  solargraph_port = 7658    # Solargraph running in socket mode.
  listen_port     = 8123    # Port for the proxy to accept client connections.
  LSPProxy.new(solargraph_host, solargraph_port, listen_port)
end

