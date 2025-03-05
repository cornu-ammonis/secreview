require 'net/http'
require 'json'
require 'uri'

SONNET_API_URL = 'http://localhost:9292/v1/messages'


def sonnet_thinking_chat(system, prompt)
  uri = URI(SONNET_API_URL)
  http = Net::HTTP.new(uri.host, uri.port)
  
  # Set SSL if the API is using HTTPS
  http.use_ssl = (uri.scheme == 'https')
  
  request = Net::HTTP::Post.new(uri)
  request['Content-Type'] = 'application/json'
  
  request.body = {
    model: 'us.anthropic.claude-3-7-sonnet-20250219-v1:0',
    messages: [
      {
        role: "user",
        content: prompt
      }
    ],
    max_tokens: 32000,
    thinking: { type: 'enabled', budget_tokens: 16000},
    stream: false 
  }.to_json
  
  response = http.request(request)
  
  if response.code.to_i == 200
    result = JSON.parse(response.body)
    puts result.inspect
    # Extract the text content from the complete response
    return result.dig('content', 1, 'text')
  else
    puts "Error: #{response.code} - #{response.body}"
    return nil
  end
end

puts sonnet_thinking_chat(nil, 'How can we reduce seat sharing in our enterprise SaaS product?')