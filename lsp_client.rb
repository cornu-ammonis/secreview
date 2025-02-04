require "socket"
require "json"

# The LSPClient class encapsulates the minimal JSON-RPC LSP client.
# It provides methods for sending requests/notifications and reading responses.
class LSPClient
  # Create a new LSPClient.
  #
  # Parameters:
  #   host         - the hostname of the LSP server (String)
  #   port         - the port number of the LSP server (Integer)
  #   project_root - the project root URI as a String (optional)
  def initialize(host:, port:, project_root: nil)
    @socket = TCPSocket.new(host, port)
    @next_id = 1
    @project_root = project_root
  end

  # Sends a JSON-RPC request to the server.
  #
  # Parameters:
  #   method - the LSP method to invoke (String)
  #   params - optional parameters for the request (Hash or nil)
  #
  # Returns the generated request id.
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

  # Sends a JSON-RPC notification (a request without an id).
  #
  # Parameters:
  #   method - the LSP method to invoke (String)
  #   params - optional parameters for the notification (Hash or nil)
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

  # Reads a complete LSP JSON-RPC message from the socket.
  #
  # Returns the parsed message as a Hash.
  def read_message
    header = ""
    # Read headers until we hit a blank line.
    until (line = @socket.gets) == "\r\n"
      raise "No header received" if line.nil?
      header << line
    end

    if header =~ /Content-Length: (\d+)/
      length = Regexp.last_match(1).to_i
      body = @socket.read(length)
      JSON.parse(body)
    else
      raise "No content length parsed from header: #{header.inspect}"
    end
  end

  # Perform the LSP handshake (initialize and initialized notifications).
  #
  # Returns the initialization response from the server.
  def initialize_handshake
    init_id = send_request("initialize", {
      "processId"   => Process.pid,
      "rootUri"     => @project_root,
      "capabilities"=> {}
    })
    init_response = read_message
    send_notification("initialized", {})
    init_response
  end

  # This method sends a workspace symbol request.
  #
  # Parameters:
  #   query - the search query string (String)
  #
  # Returns the parsed JSON response from the server.
  def workspace_symbol(query)
    req_id = send_request("workspace/symbol", { "query" => query })
    read_message
  end

  # Optionally add more high-level methods for other LSP functionality.
end

# If the file is executed directly, run an interactive demo.
if __FILE__ == $PROGRAM_NAME
  # Example configuration – adjust these as needed.
  SERVER_HOST = "localhost"
  SERVER_PORT = 7658   # Change as required.
  PROJECT_ROOT = "file:///Users/andrew/Documents/aha/aha-app"  # As a URI

  # Instantiate our LSP client.
  client = LSPClient.new(host: SERVER_HOST, port: SERVER_PORT, project_root: PROJECT_ROOT)

  # Initialize the session.
  init_response = client.initialize_handshake
  puts "Initialize response: #{init_response.inspect}"

  # Interactive query demo.
  puts "Type a search query (or type 'exit' to quit):"
  while (query = gets.chomp) && query != "exit"
    response = client.workspace_symbol(query)
    if response["error"]
      puts "Error: #{response["error"]}"
    else
      symbols = response["result"] || []
      # For demo purposes, just show the first symbol.
      if first_sym = symbols.first
        kind  = first_sym["kind"]
        name  = first_sym["name"]
        uri   = first_sym.dig("location", "uri")
        line  = first_sym.dig("location", "range", "start", "line")
        puts "#{kind}: #{name} at #{uri}:#{line}"
      else
        puts "No symbols found for query: #{query}"
      end
    end
    puts "Type another query (or 'exit'):"
  end
  puts "Goodbye!"
end