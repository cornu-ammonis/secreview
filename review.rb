#!/usr/bin/env ruby

require 'openai'
require 'json'
require 'find'
require_relative 'lsp_client'

# Global limits to prevent runaway recursive queries.
MAX_TOTAL_QUESTIONS = 20
MAX_DEPTH = 5

# SYSTEM PROMPTS

SYSTEM_PROMPT_QUESTIONS = <<~PROMPT
  You are an expert security code reviewer for Ruby on Rails applications. 
  For each file you are given, if you detect a potential security issue that might depend on code 
  that is not visible in the current file, generate a Code Search Request (CSR). 
  You may generate up to 10 CSRs. 
  Each CSR must include:
  1. "question": A clear explanation of the security concern (with logical rationale and impact) and what code, not present in the current file, that you need to see to resolve it.
  2. "example": An excerpt from the provided file that raised the concern.
  3. "workspace_symbol": An LSP workspace symbol query to find the method or class elsewhere in the codebase.
  
  These code questions will be resolved into code snippets for your final review, so think carefully about what external context you want to see.
  Consider that both serious false negatives and excessive false positives are problematic; too many concerns is noise, but missing a serious Rails application security issue could have dire consequences. Please think carefully and thanks!
PROMPT

SYSTEM_PROMPT_RESOLVE_QUESTION = <<~PROMPT
  You are an expert security code reviewer for Ruby on Rails applications.
  You have previously generated a Code Search Request (CSR) for a given file.
  Below is the original CSR and the associated code snippet(s) retrieved.
  Please analyze the snippet(s) along with the original request.
  If the snippet(s) resolve your concern, set "status" to "resolved", provide a clear explanation in "commentary", and include a new key "resolved_code" with the exact piece or pieces of code that you judge sufficient to address the concern.
  If the snippet(s) do not resolve the issue, set "status" to "unresolved", provide commentary, and supply a *new* workspace_symbol to try a different LSP query.
  Do not choose a symbol for your query that exactly matches a previous query.
  Your output should be valid JSON with the following keys:
  1. "status": either "resolved" or "unresolved"
  2. "commentary": an explanation of why the snippet(s) resolve (or do not resolve) the concern
  3. "workspace_symbol": a new LSP workspace symbol query if further context is needed (leave empty if not)
  4. "resolved_code": if status is "resolved", include the specific code piece(s) that resolved the concern (otherwise leave empty)
PROMPT

SYSTEM_PROMPT_FINAL_REVIEW = <<~PROMPT
  You are an expert security code reviewer for Ruby on Rails applications.
  Please review the following file and the associated resolved code snippets carefully. The resolved code snippets were retrieved based on questions that you generated earlier as they seemed contextually relevant for the review.
  In your output, separate ISSUES, CONCERNS, and COMMENTARY. If there are no issues identified, simply state "no issues identified" for ISSUES.
  Consider that both serious false negatives and excessive false positives are problematic; too many concerns is noise, but missing a serious Rails application security issue could have dire consequences. Please think carefully and thanks!
PROMPT

MODEL       = 'o3-mini'
OUTPUT_FILE = 'results.txt'

# Create an OpenAI client. (Make sure OPENAI_API_KEY is set in your environment.)
client = OpenAI::Client.new(access_token: ENV.fetch('OPENAI_API_KEY'))

# Helper: send a chat request and return the model's reply.
def call_chat(client, messages, reasoning_effort: 'high')
  response = client.chat(
    parameters: {
      model: MODEL,
      messages: messages,
      reasoning_effort: reasoning_effort
    }
  )
  response.dig('choices', 0, 'message', 'content')
rescue StandardError => e
  puts "Error during API call: #{e.message}"
  nil
end

# Generates initial code questions (CSRs) for a file's content.
def generate_code_questions(client, file_content)
  messages = [
    { 'role' => 'system', 'content' => SYSTEM_PROMPT_QUESTIONS },
    { 'role' => 'user',
      'content' => "Please analyze the following Ruby code and output any Code Search Requests (CSRs) as described. Include for each CSR a 'question', an 'example', and a 'workspace_symbol'. Do not include any extra text - only output valid JSON.\n\n#{file_content}" }
  ]
  response_text = call_chat(client, messages, reasoning_effort: 'high')
  begin
    cq_array = JSON.parse(response_text)
    return [] unless cq_array.is_a?(Array)
    cq_array.select { |cq| cq.is_a?(Hash) && cq.key?('question') && cq.key?('example') && cq.key?('workspace_symbol') }
  rescue JSON::ParserError => e
    puts "Error parsing Code Questions JSON: #{e.message}"
    []
  end
end

# Resolves a single code question by feeding the retrieved multi-snippet context to GPT.
def resolve_code_question(client, code_question, multi_snippet)
  messages = [
    { 'role' => 'system', 'content' => SYSTEM_PROMPT_RESOLVE_QUESTION },
    { 'role' => 'user', 'content' => "Here is the original Code Search Request:\n\n#{code_question.to_json}\n\nAnd here are the retrieved code snippet(s):\n\n#{multi_snippet}\n\nPlease analyze and let me know if this resolves the concern. If it does, include a key \"resolved_code\" with only the specific piece(s) of code that answer the concern." }
  ]
  response_text = call_chat(client, messages, reasoning_effort: 'medium')
  begin
    res = JSON.parse(response_text)
    if res.is_a?(Hash) && res.key?('status') && res.key?('commentary') && res.key?('workspace_symbol') && res.key?('resolved_code')
      res
    else
      { 'status' => 'error', 'commentary' => 'Invalid response format', 'workspace_symbol' => '', 'resolved_code' => '' }
    end
  rescue JSON::ParserError => e
    puts "Error parsing resolution JSON: #{e.message}"
    { 'status' => 'error', 'commentary' => 'JSON parsing error', 'workspace_symbol' => '', 'resolved_code' => '' }
  end
end

# --- Main Script ---
# 

if ARGV.length != 1
  puts "Usage: ruby enhanced_process_files.rb <project_root>"
  exit 1
end

project_root = "file://#{ARGV[0]}"
puts project_root
puts "Initializing LSP client..."
lsp_client = LSPClient.new(
  host: "localhost",
  port: 8123,
  project_root: project_root
)
lsp_client.initialize_handshake
puts "LSP client initialized."

puts "Enter the path to the file or directory you want to review (or type 'exit' to quit):"
while (input_path = STDIN.gets.chomp) && input_path != "exit"
  files = []
  if File.directory?(input_path)
    Find.find(input_path) { |path| files << path if File.file?(path) }
  elsif File.file?(input_path)
    files << input_path
  else
    puts "The specified path is not a file or directory, please try again."
    next
  end

  final_review_results = []

  files.each do |filepath|
    start_time = Time.now

    puts "\nProcessing file: #{filepath}..."
    begin
      file_content = File.read(filepath)
    rescue => e
      puts "Error reading #{filepath}: #{e.message}"
      next
    end

    file_result = { file: filepath, code_questions: [] }
    initial_cqs = generate_code_questions(client, file_content)
    puts "Found #{initial_cqs.length} initial Code Questions in #{filepath}."

    # Create a queue for code questions.
    question_queue = []
    initial_cqs.each do |cq|
      cq["depth"] = 0
      question_queue << cq
    end

    resolved_questions = []
    total_questions = 0

    # Process the queue until empty or we hit our maximum question limit.
    while !question_queue.empty? && total_questions < MAX_TOTAL_QUESTIONS
      current_cq = question_queue.shift
      total_questions += 1
      puts "\nProcessing Code Question: #{current_cq['question']} (Symbol: #{current_cq['workspace_symbol']}, Depth: #{current_cq['depth']})"

      # Retrieve up to 10 snippet matches from LSP.
      multi_snippet = lsp_client.get_multi_snippet(current_cq["workspace_symbol"], 10)

      resolution = resolve_code_question(client, current_cq, multi_snippet)
      puts "\nResolution: #{resolution.inspect}"

      if resolution["status"] == "resolved"
        resolved_questions << {
          question: current_cq["question"],
          example: current_cq["example"],
          workspace_symbol: current_cq["workspace_symbol"],
          resolved_code: resolution["resolved_code"],
          commentary: resolution["commentary"],
          depth: current_cq["depth"],
          status: "resolved"
        }
      elsif resolution["status"] == "unresolved" && !resolution["workspace_symbol"].to_s.strip.empty?
        # If a new symbol is provided and we haven't exceeded max depth, queue a new question.
        new_depth = current_cq["depth"] + 1
        if new_depth < MAX_DEPTH
          new_cq = {
            "question" => "#{current_cq["question"]}\n Follow-up for additional context: #{resolution['workspace_symbol']} \n previous_symbol, don't query this again: #{current_cq['workspace_symbol']}\n",
            "example" => current_cq["example"],
            "workspace_symbol" => resolution["workspace_symbol"],
            "depth" => new_depth
          }
          question_queue << new_cq
          puts "Queued new Code Question for symbol: #{resolution['workspace_symbol']} (Depth: #{new_depth})"
        else
          # Exceeded max depth; record as unresolved (do not include multi-snippet code).
          resolved_questions << {
            question: current_cq["question"],
            example: current_cq["example"],
            workspace_symbol: current_cq["workspace_symbol"],
            resolved_code: "",
            commentary: "Max recursion depth reached. " + resolution["commentary"],
            depth: current_cq["depth"],
            status: "unresolved"
          }
        end
      else
        # No further symbol provided; mark as unresolved and do not include the multi-snippet code.
        resolved_questions << {
          question: current_cq["question"],
          example: current_cq["example"],
          workspace_symbol: current_cq["workspace_symbol"],
          resolved_code: "",
          commentary: "Unresolved: " + resolution["commentary"],
          depth: current_cq["depth"],
          status: "unresolved"
        }
      end
    end

    puts "preparing final review...."

    file_result[:code_questions] = resolved_questions
    final_review_results << file_result

    # Build the final resolved code string by including only questions marked as "resolved".
    file_resolved_codes = resolved_questions.select { |rq| rq[:status] == "resolved" }.map do |rq|
      "Question: #{rq[:question]}\nWorkspace Symbol: #{rq[:workspace_symbol]}\nResolved Code:\n#{rq[:resolved_code]}\nCommentary: #{rq[:commentary]}"
    end.join("\n\n===\n\n")

    # If no question was ever resolved, do not include any snippet code.
    final_user_content = if file_resolved_codes.strip.empty?
                           "Here is the file under review:\n\n#{file_content}\n\nNo resolved code snippets were obtained from the Code Search Requests."
                         else
                           "Here is the file under review:\n\n#{file_content}\n\nBelow are the resolved code snippets:\n\n#{file_resolved_codes}"
                         end

    final_messages = [
      { 'role' => 'system', 'content' => SYSTEM_PROMPT_FINAL_REVIEW },
      { 'role' => 'user', 'content' => final_user_content + "\n\nPlease provide your final security review." }
    ]

    puts "executing final review..."
    final_review_response = call_chat(client, final_messages)

    File.open(OUTPUT_FILE, 'a') do |out_file|
      out_file.puts "Enhanced Security Review Results for File: #{filepath}"
      out_file.puts "=================================="
      resolved_questions.each do |rq|
        out_file.puts "--------------------------------------------"
        out_file.puts "Code Question: #{rq[:question]}"
        out_file.puts "Example: #{rq[:example]}"
        out_file.puts "Workspace Symbol: #{rq[:workspace_symbol]}"
        out_file.puts "Commentary: #{rq[:commentary]}"
        # Only print the resolved code if the question was resolved.
        if rq[:status] == "resolved"
          out_file.puts "Resolved Code:\n#{rq[:resolved_code]}"
        end
      end
      out_file.puts "\nFinal Security Review:"
      out_file.puts final_review_response
      out_file.puts "\n==================================\n"
    end

    puts "Review results for #{filepath} saved to #{OUTPUT_FILE}. Took #{Time.now - start_time} seconds."
  end

  puts "Enhanced security review complete. Results saved to #{OUTPUT_FILE}."
end

puts "Disconnecting LSP client..."
lsp_client.disconnect
