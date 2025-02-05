#!/usr/bin/env ruby
# enhanced_process_files.rb

require 'openai'
require 'find'
require 'json'
require 'shellwords' # Needed for safely escaping shell parameters
require 'open3'
require_relative 'lsp_client'


# CONSTANTS – adjust these as needed.
# SYSTEM_PROMPT includes instructions for generating Code Questions (CQs).
SYSTEM_PROMPT_QUESTIONS = "You are an expert security code reviewer for Ruby on Rails applications. For each file you are given, if you detect a potential security issue that might depend on code that is not visible in the current file, generate a Code Question (CQ). You may generate up to 10 CQs. Each CQ must include:
1. \"question\": A clear explanation of the security concern (with logical rationale and impact).
2. \"example\": An excerpt from the provided file that raised the concern.
3. \"workspace_symbol\": An LSP workspace symbol query to find the method or class elsewhere in the codebase to resolve the concern. Example: if you want to see a method called like example.some_method, simply put some_method in this field. Or similarly you might search for a classname. 
  
These code questions will be resolved into code snippets for your final review, so think carefully about what external context you want to conduct a final review. 
Consider that both serious false negatives and excessive false positives are problematic; too many concerns and it's noise, but missing a serious Rails application security issue could have dire consequences. Please thank carefully and thanks!
"


SYSTEM_PROMPT_FINAL_REVIEW = "You are an expert security code reviewer for Ruby on Rails applications.
Please review the following  file and associated code snippets carefully. The code snippets were retrieved based on questions that you generated earlier as they seemed contextually relevant for the review. 
In your output you should separate ISSUES, CONCERNS, and COMMENTARY. CONCERNS are places where further investigation is required. ISSUES are places where you have identified an actual security issue. COMMENTARY is where you may include analysis for why things are not issues. If there are no issues identified, don't tell me why things are secure (that's for COMMENTARY), simply say no issues identified.
Consider that both serious false negatives and excessive false positives are problematic; too many concerns and it's noise, but missing a serious Rails application security issue could have dire consequences. Please thank carefully and thanks!
"

MODEL         = 'o3-mini' # Change this to the model you want to use.
OUTPUT_FILE   = 'results.txt'

# Create an OpenAI client; ensure your API key is set in the environment.
client = OpenAI::Client.new(access_token: ENV.fetch('OPENAI_API_KEY'))


# Helper: send a chat request and return the model's reply.
def call_chat(client, messages, reasoning_effort: 'high')
    response = client.chat(
      parameters: {
        model: MODEL,
        messages:,
        reasoning_effort: reasoning_effort
      }
    )
    response.dig('choices', 0, 'message', 'content')
rescue StandardError => e
    puts "Error during API call: #{e.message}"
    nil
end

# Helper: Generate Code Questions for a given file’s content.
def generate_code_questions(client, file_content)
  messages = [
    { 'role' => 'system', 'content' => SYSTEM_PROMPT_QUESTIONS },
    { 'role' => 'user',
      'content' => "Please analyze the following Ruby code and output any Code Questions (CQs) as described. Include for each CQ a 'question', an 'example', and a 'workspace_symbol'. Do not include any extra text - only output valid JSON.\n\n#{file_content}" }
  ]
  response_text = call_chat(client, messages, reasoning_effort: 'high')
  begin
    cq_array = JSON.parse(response_text)
    # Validate that we have an array of objects with all required keys.
    return [] unless cq_array.is_a?(Array)

      cq_array.select do |cq|
        cq.is_a?(Hash) && cq.key?('question') && cq.key?('example') && cq.key?('workspace_symbol')
      end
  rescue JSON::ParserError => e
    puts "Error parsing Code Questions JSON: #{e.message}"
    []
  end
end

def search_files_by_regex(codebase_root, regex_str)  
  # Escape the regex and the codebase_root to prevent shell issues
  escaped_regex = Shellwords.escape(regex_str)
  escaped_path  = Shellwords.escape(codebase_root)
  
  # Construct the grep command: -r to search recursively, -l to list only file names, -E for extended regex
  command = "grep -rEl #{escaped_regex} #{escaped_path}"
  puts "executing command #{command}"
  # Execute the grep command using Open3 for better error handling
  begin
    stdout, stderr, status = Open3.capture3(command)
    
    if status.success?
      stdout.split("\n")
    else
      raise "Grep command failed: #{stderr} #{stdout}"
    end
  rescue StandardError => e
    puts "Error executing search: #{e.message} #{e.inspect}"
    return ""
  end
end


puts "initializing lsp client...."
lsp_client = LSPClient.new(
 host: "localhost",
 port: 7658,
 project_root: "file:///Users/andrew/Documents/aha/aha-app"
)
lsp_client.initialize_handshake

puts "client initialized"
puts "enter the path to the file or directory you want to review"
# Main script logic.
while (input_path = gets.chomp) && input_path != "exit"
  # Gather all files (if a directory, search recursively; if a file, process it alone).
  files = []
  if File.directory?(input_path)
    Find.find(input_path) do |path|
      files << path if File.file?(path)
    end
  elsif File.file?(input_path)
    files << input_path
  else
    puts 'The specified path is not a file or directory, please try again'
  end

  # Process each file and record review results.
  final_review_results = [] # Will hold details per file.
  all_resolved_snippets = [] # Will accumulate all resolved code snippet texts.

  files.each do |filepath|
    puts "Processing file: #{filepath}..."
    begin
      file_content = File.read(filepath)
    rescue StandardError => e
      puts "Error reading #{filepath}: #{e.message}"
      next
    end

    # Container for results from this file.
    file_result = { file: filepath, cqs: [] }

    # Generate Code Questions (CQs) for this file.
    cqs = generate_code_questions(client, file_content)
    puts "Found #{cqs.length} Code Questions in #{filepath}."

    cqs.each_with_index do |cq, i|
      puts "trying cq #{i} with query #{cq['workspace_symbol']}"
      cq_result = { question: cq['question'], example: cq['example'], workspace_symbol: cq['workspace_symbol'], status: 'unresolved',
                    resolved_snippet: nil }

      begin 
        cq_snippet = lsp_client.get_workspace_snippet(cq['workspace_symbol'])
      rescue StandardError => e
        puts "Error resolving CQ #{i}: #{e.message}"
        cq_snippet = ''
      end

      if cq_snippet.downcase == 'none' || cq_snippet.empty?
        cq_result[:status] = 'unresolved (no snippet extracted)'
      else
        cq_result[:status] = 'resolved'
        cq_result[:resolved_snippet] = cq_snippet
        all_resolved_snippets << "Question: " + cq['question'] + "\n Snippet: \n" + cq_snippet
      end

      file_result[:cqs] << cq_result
    end

    final_review_results << file_result

    # Now perform a final review using all the resolved code snippets.
    final_snippets_text = all_resolved_snippets.join("\n\n===\n\n")
    final_messages = [
      { 'role' => 'system', 'content' => SYSTEM_PROMPT_FINAL_REVIEW },
      { 'role' => 'user',
        'content' => "Here is the file under review: \n\n #{file_content}\n\n\nBelow are the code snippets that were extracted as resolving some Code Questions:\n\n#{final_snippets_text}\n\n Please review the code carefully for any security issues." }
    ]
    final_review_response = call_chat(client, final_messages)

    # Write the full review results to the output file.
    File.open(OUTPUT_FILE, 'a') do |out_file|
      out_file.puts 'Enhanced Security Review Results:'
      out_file.puts '=================================='
      final_review_results.each do |file_res|
        out_file.puts "File: #{file_res[:file]}"
        file_res[:cqs].each do |cq|
          out_file.puts '--------------------------------------------'
          out_file.puts "Code Question: #{cq[:question]}"
          out_file.puts "Example: #{cq[:example]}"
          out_file.puts "Workfspace Symbol: #{cq[:workspace_symbol]}"
          out_file.puts "Status: #{cq[:status]}"
          out_file.puts "Resolved Snippet:\n#{cq[:resolved_snippet]}" if cq[:resolved_snippet]
        end
        out_file.puts "\n"
      end
      out_file.puts 'Final Security Review Based on Resolved Snippets:'
      out_file.puts final_review_response
      out_file.puts "\n==================================\n"
    end

    puts "Review results for #{filepath} saved to #{OUTPUT_FILE}."
  end

  puts "Enhanced security review complete. Results saved to #{OUTPUT_FILE}."
end