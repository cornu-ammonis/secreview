#!/usr/bin/env ruby
# lsp_client.rb

require 'socket'
require 'json'
require 'uri'

class LSPClient
  def initialize(host:, port:, project_root:)
    @host = host
    @port = port
    @project_root = project_root
    @socket = TCPSocket.new(@host, @port)
    @socket.set_encoding("BINARY")
  end

  # Perform the initial LSP handshake.
  def initialize_handshake
    handshake = {
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => {
        "processId"   => Process.pid,
        "rootUri"     => @project_root,
        "capabilities" => {}
      }
    }
    send_message(handshake)
    response = read_message
    # Optionally, send an "initialized" notification.
    init_notif = {
      "jsonrpc" => "2.0",
      "method" => "initialized",
      "params" => {}
    }
    send_message(init_notif)
    response
  end

  # Cleanly disconnect the socket.
  def disconnect
    @socket.close if @socket && !@socket.closed?
  end

  # Sends an LSP message (with proper headers) to the server.
  def send_message(msg)
    data = JSON.generate(msg)
    full_message = "Content-Length: #{data.bytesize}\r\n\r\n#{data}"
    @socket.write(full_message)
  end

  # Reads an LSP message (header and body) from the socket.
  def read_message
    header = ""
    while (line = @socket.gets)
      break if line == "\r\n"
      header << line
    end
    return nil if header.strip.empty?
    if header =~ /Content-Length: (\d+)/
      length = Regexp.last_match(1).to_i
      body = @socket.read(length)
      JSON.parse(body)
    else
      nil
    end
  rescue => e
    puts "Error reading message: #{e}"
    nil
  end

  # Retrieves up to `limit` snippet matches for a given workspace symbol.
  # It sends a "workspace/symbol" request to the LSP and then fetches a text excerpt
  # for each location.
  def get_multi_snippet(query, limit = 10)
    request = {
      "jsonrpc" => "2.0",
      "id" => 2,  # Ensure a unique id or manage id sequencing.
      "method" => "workspace/symbol",
      "params" => { "query" => query }
    }
    send_message(request)
    response = read_message
    results = response["result"] rescue []
    unless results.is_a?(Array)
      return "No results found for symbol: #{query}"
    end
    results = results.first(limit)
    snippets = results.map.with_index do |result, index|
      snippet_text = fetch_snippet_from_location(result["location"])
      "Snippet #{index+1} (#{result['name']}):\n#{snippet_text}"
    end
    snippets.join("\n\n===\n\n")
  end

  # Given a location hash (with "uri" and "range"), fetch a snippet from the file.
  def fetch_snippet_from_location(location)
    uri = location["uri"]
    # Convert file URI to a file path.
    file_path = URI(uri).path
    begin
      content = File.read(file_path)
      lines = content.split("\n")
      range = location["range"]
      start_line = range["start"]["line"] rescue 0
      end_line = range["end"]["line"] rescue start_line
      snippet_lines = lines[start_line..end_line] || []
      snippet_lines.join("\n")
    rescue => e
      "Error retrieving snippet from #{file_path}: #{e.message}"
    end
  end
end
