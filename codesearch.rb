#!/usr/bin/env ruby
require "socket"
require "json"

# Define our minimal LSP client.
class LSPClient
  def initialize(host, port)
    @socket = TCPSocket.new(host, port)
    @next_id = 1
  end

  def send_request(method, params = nil)
    id = @next_id
    @next_id += 1
    request = {
      "jsonrpc" => "2.0",
      "id"      => id,
      "method"  => method,
      "params"  => params
    }
    data = JSON.generate(request)
    message = "Content-Length: #{data.bytesize}\r\n\r\n#{data}"
    @socket.write(message)
    id
  end

  def send_notification(method, params = nil)
    notification = {
      "jsonrpc" => "2.0",
      "method"  => method,
      "params"  => params
    }
    data = JSON.generate(notification)
    message = "Content-Length: #{data.bytesize}\r\n\r\n#{data}"
    @socket.write(message)
  end

  def read_message
    # Read headers until we hit a blank line.
    header = ""
    until (line = @socket.gets) == "\r\n"
      raise "No header received" if line.nil?
      header << line
    end

    if header =~ /Content-Length: (\d+)/
      length = $1.to_i
      body = @socket.read(length)
      JSON.parse(body)
    else
      raise "No content length parsed from header: #{header.inspect}"
    end
  end
end

# Configuration – adjust these as needed:
SERVER_HOST = "localhost"
SERVER_PORT = 7658  # Change this to the port your ruby-lsp server is listening on
PROJECT_ROOT = "file:///Users/andrew/Documents/aha/aha-app"  # As a URI

# Now we can instantiate our LSP client.
client = LSPClient.new(SERVER_HOST, SERVER_PORT)

# Proceed with the LSP handshake, etc.
init_id = client.send_request("initialize", {
  "processId" => Process.pid,
  "rootUri" => PROJECT_ROOT,
  "capabilities" => {}
})
init_response = client.read_message
puts "Initialize response: #{init_response.inspect}"

client.send_notification("initialized", {})

puts "Type a search query (or type 'exit' to quit):"
while (query = gets.chomp) && query != "exit"
  req_id = client.send_request("workspace/symbol", { "query" => query })
  response = client.read_message
  if response["error"]
    puts "Error: #{response["error"]}"
  else
    symbols = response["result"] || []
    #symbols.each do |sym|
    sym = symbols[0]
      puts "#{sym["kind"]}: #{sym["name"]} at #{sym.dig("location", "uri")}:#{sym.dig("location", "range", "start", "line")}"
    #end
  end
  puts "Type another query (or 'exit'):"
end

puts "Goodbye!"  