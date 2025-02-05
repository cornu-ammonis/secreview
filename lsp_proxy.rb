#!/usr/bin/env ruby
require 'socket'
require 'thread'

# A simple persistent TCP proxy that maintains one connection to the upstream
# Solargraph server and forwards messages to/from any temporarily connected client.
# This is optional, but it makes it easier to iterate on the client/script code because we don't need to restart Solargraph every time we run the client.
class LSPProxy
  # solargraph_host: host where Solargraph is running (e.g., "localhost")
  # solargraph_port: port for Solargraph (e.g., 7658 in socket mode)
  # listen_port: local port where the proxy listens for client connections (e.g., 8123)
  def initialize(solargraph_host, solargraph_port, listen_port)
    @solargraph_host = solargraph_host
    @solargraph_port = solargraph_port
    @listen_port      = listen_port

    # Establish a persistent connection to the Solargraph server.
    @sg_socket = TCPSocket.new(@solargraph_host, @solargraph_port)
    @sg_socket.set_encoding('BINARY')
    puts "Connected persistently to Solargraph at #{@solargraph_host}:#{@solargraph_port}"

    # This will hold the currently connected client (if any).
    @client_mutex   = Mutex.new
    @current_client = nil

    # Start a thread that continuously reads from Solargraph and
    # forwards any data to the connected client.
    start_sg_reader_thread

    # Listen for client connections.
    start_client_listener
  end

  # Continuously reads from the Solargraph socket.
  # When a client is connected (held in @current_client), the data is forwarded.
  # If there is no client, the data is discarded (or you could choose to buffer it).
  def start_sg_reader_thread
    Thread.new do
      loop do
        begin
          data = @sg_socket.readpartial(4096)
          @client_mutex.synchronize do
            if @current_client
              begin
                @current_client.write(data)
              rescue IOError => e
                puts "Error writing to client: #{e}"
                @current_client = nil
              end
            else
              # When no client is connected, you can log or discard data.
              # For example: puts "No client connected; discarding data."
            end
          end
        rescue EOFError, IOError => e
          puts "Solargraph connection lost: #{e}"
          break
        end
      end
    end
  end

  # Listens for incoming client connections.
  # Each client connection will be handled sequentially.
  def start_client_listener
    server = TCPServer.new(@listen_port)
    puts "Proxy is listening for client connections on port #{@listen_port}"
    loop do
      client = server.accept
      puts "Client connected from #{client.peeraddr.last}"
      handle_client(client)
      puts "Client disconnected"
    end
  end

  # For a connected client, forward its input to Solargraph.
  # (Solargraph’s responses are already being forwarded by the sg-reader thread.)
  def handle_client(client)
    client.set_encoding('BINARY')
    @client_mutex.synchronize { @current_client = client }
    begin
      loop do
        data = client.readpartial(4096)
        @sg_socket.write(data)
      end
    rescue EOFError, IOError => e
      puts "Client connection error: #{e}"
    ensure
      @client_mutex.synchronize { @current_client = nil }
      client.close rescue nil
    end
  end
end

# To run the proxy as a standalone process, adjust these settings if needed.
if __FILE__ == $PROGRAM_NAME
  solargraph_host = 'localhost'
  solargraph_port = 7658   # Port where Solargraph runs in socket mode.
  listen_port     = 8123   # Port where proxy listens for client connections.
  LSPProxy.new(solargraph_host, solargraph_port, listen_port)
end

