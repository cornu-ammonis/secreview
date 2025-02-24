#!/usr/bin/env ruby

require 'openai'
require 'json'
require 'find'
require_relative 'lsp_client'

# Global limits to prevent runaway recursive queries.
MAX_TOTAL_QUESTIONS = 20
MAX_DEPTH = 2
MOA = true
TIMEOUT_SECONDS = 45  # adjust the timeout duration as needed


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

SYSTEM_PROMPT_PARANOID = <<~PROMPT
You are an expert security code reviewer for Ruby on Rails applications. 
You are particularly paranoid, speculating about potential problems or seeing more deeply into interactions than the average person. 
This paranoia does come with commentary about likelihood, and it will be up to a downstream judge to decide whether your overly rigorous analysis is proportional to the problem at hand. 
Leave no stone unturned, but do not create excessive noise in your output.

You will be given code as well as a list of resolved and unresolved code search questions. The questions should help guide your review,
but they are not the only thing to consider. You should also flag any issues that are unrelated to the questions.

In your output, separate ISSUES, CONCERNS, and COMMENTARY. If there are no issues identified, simply state "no issues identified" for ISSUES.
PROMPT

SYSTEM_PROMPT_JUSTIFIER = <<~PROMPT
You are an expert principal engineer for Ruby on Rails applications assisting in a security review.
You are adept at explaining or justifying decisions, but you do also recognize when something is a real issue.
Part of the value that you add is by recognizing what might be flagged as a potential security issue, 
but explaining how we could determine that it is not actually a problem - or observing that we do have enough information 
to verify it is not a problem. You may also flag particularly interesting choices or things that deviate from Rails best practices, 
but only if they have a potential security impact. 
If something looks likely to cause an actual user facing bug or error, even if there is no direct security impact, 
you should note that as an issue.

You will be given code as well as a list of resolved and unresolved code search questions. The questions should help guide your review,
but they are not the only thing to consider. You should also flag any issues that are unrelated to the questions. 

In your output, separate ISSUES, CONCERNS, and COMMENTARY. 
If there are no issues identified, simply state "no issues identified" for ISSUES.
PROMPT

SYSTEM_PROMPT_GENERIC = <<~PROMPT
You are an expert security code reviewer for Ruby on Rails applications.

Please review the following file and the associated resolved code snippets carefully.
You will be given code as well as a list of resolved and unresolved code search questions. The questions should help guide your review,
but they are not the only thing to consider. You should also flag any issues that are unrelated to the questions.

In your output, separate ISSUES, CONCERNS, and COMMENTARY. If there are no issues identified, simply state "no issues identified" for ISSUES.

Consider that both serious false negatives and excessive false positives are problematic; too many concerns is noise,
but missing a serious Rails application security issue could have dire consequences. Please think carefully and thanks!
PROMPT

SYSTEM_PROMPT_PRINCIPAL = <<~PROMPT
You are a principal level security engineer finalizing a security review for some Ruby on Rails application code. 
You have well-balanced and strategic judgement, highlighting critical issues without fail, and providing prudent commentary on more ambiguous risks — 
even making the choice to omit minor risks or concerns when you judge that they are not worth the time to analyze. 
You will receive both application code and the commentary from previous reviewers. 
You should review it all holistically, balancing the diverse opinions of your collaborators, 
and conducting your own final review of the code to produce the ultimate output which will be reviewed by the decisionmaker. 
Note that your job is not only to review what your colleagues have said; they might have missed something, 
so also conduct your own expert review of the code and consider that for the final output. 

In your output, separate ISSUES, CONCERNS, and COMMENTARY. 
If there are no issues identified, simply state "no issues identified" for ISSUES.

Consider that both false negatives and excessive false positives are problematic. Too many concerns is noise, but missing a serious Rails application security issue could have dire consequences. Please think carefully and thanks!
PROMPT

SYSTEM_PROMPT_PRINCIPAL_NO_CONTEXT = <<~PROMPT
You are a principal level security engineer finalizing a security review for some Ruby on Rails application code. 
You have well-balanced and strategic judgement, highlighting critical issues without fail, and providing prudent commentary on more ambiguous risks — 
even making the choice to omit minor risks or concerns when you judge that they are not worth the time to analyze. 
You will receive application code which you should rigorously anaylze for security problems, prioritizing the most severe potential problems as you reason. 

In your output, separate ISSUES, CONCERNS, and COMMENTARY. 
If there are no issues identified, simply state "no issues identified" for ISSUES.

Consider that a false positive missing applications security issues could be devastating, particularly if they risk customer data 
exposure either directly or via insecure practices. False positives are also problematic but at this stage, 
prioritize capturing all relevant issues as we will strip out less relevant ones later. 
PROMPT

PARALLEL_AGENT_PROMPTS = [SYSTEM_PROMPT_PARANOID, SYSTEM_PROMPT_JUSTIFIER, SYSTEM_PROMPT_GENERIC, SYSTEM_PROMPT_PRINCIPAL_NO_CONTEXT]

MODEL       = 'o3-mini'
OUTPUT_FILE = 'results.txt'
AGENT_OUTPUT_FILE = 'agent_results.txt'
QUESTIONS_OUTPUT_FILE = 'questions.txt'

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

def mixture_of_agents_final_review(client, code_inputs, file_alone, filepath)
  threads = PARALLEL_AGENT_PROMPTS.map do |prompt|
    Thread.new do
      content = if prompt == SYSTEM_PROMPT_PRINCIPAL_NO_CONTEXT
        puts "executing this agent on file alone..."
        file_alone
      else
        puts "executing agent..."
        code_inputs
      end
      messages = [
        { role: "system", content: prompt },
        { role: "user", content: content }
      ]
      call_chat(client, messages, reasoning_effort: 'high')
    end
  end
  
  responses = threads.map(&:value)

  multi_agent_result = ""
  responses.each_with_index do |response, i| 
    multi_agent_result += "Reviewer #{i+1}:\n"
    if response.nil?
      multi_agent_result += "Error: No response from reviewer #{i+1}\n\n"
    else 
      multi_agent_result += response + "\n\n"
    end
  end

  File.open(AGENT_OUTPUT_FILE, 'a') do |out_file|
    out_file.puts "intermediate multi-agent results for File: #{filepath}"
    out_file.puts "=================================="
    out_file.puts multi_agent_result
    out_file.puts "\n==================================\n"
  end

  puts "executing final review..."

  final_messages = [
        { 'role' => 'system', 'content' => SYSTEM_PROMPT_PRINCIPAL },
        { 'role' => 'user', 'content' => code_inputs + "\n\n" + multi_agent_result + "\n\nPlease provide your final security review." }
      ]
  
  call_chat(client, final_messages)
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
  response_text = call_chat(client, messages, reasoning_effort: 'low')
  begin
    res = JSON.parse(response_text)
    if res.is_a?(Hash) && res.key?('status') && res.key?('commentary') && res.key?('workspace_symbol') && res.key?('resolved_code')
      res
    else
      { 'status' => 'error', 'commentary' => 'Invalid response format', 'workspace_symbol' => '', 'resolved_code' => '' }
    end
  rescue StandardError => e
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
    question_queues = []
    MAX_DEPTH.times do |i|
      question_queues << []
    end
    initial_cqs.each do |cq| 
      question_queues[0] << [cq, lsp_client.get_multi_snippet(cq["workspace_symbol"], 10)]
    end

    resolved_questions = []
    total_questions = 0
    depth = 0


    while depth < MAX_DEPTH
      question_queue = question_queues[depth]
    
      # Each thread will perform its work and return a result hash.
      thread_results = question_queue.map do |entry|
        current_question, multi_snippet = entry
        Thread.new do
          begin
            # Wrap the whole thread’s execution in a timeout block.
            Timeout.timeout(TIMEOUT_SECONDS) do
              # Capture current depth for use inside this thread.
              current_depth = depth
              result = { resolved: nil, queued: nil }
    
              puts "\nProcessing Code Question: #{current_question['question']} (Symbol: #{current_question['workspace_symbol']})"
              resolution = resolve_code_question(client, current_question, multi_snippet)
              puts "\nResolution: #{resolution.inspect}"
    
              if resolution["status"] == "resolved"
                result[:resolved] = {
                  question: current_question["question"],
                  example: current_question["example"],
                  workspace_symbol: current_question["workspace_symbol"],
                  resolved_code: resolution["resolved_code"],
                  commentary: resolution["commentary"],
                  status: "resolved"
                }
              elsif resolution["status"] == "unresolved" &&
                    !resolution["workspace_symbol"].to_s.strip.empty? &&
                    resolution["workspace_symbol"].to_s.strip != current_question["workspace_symbol"].to_s.strip
                new_depth = current_depth + 1
                if new_depth < MAX_DEPTH
                  new_question = {
                    "question" => "#{current_question["question"]}\n Follow-up for additional context: #{resolution['workspace_symbol']} \n(previous symbol: #{current_question['workspace_symbol']}, don't query this again)",
                    "example" => current_question["example"],
                    "workspace_symbol" => resolution["workspace_symbol"]
                  }
                  result[:queued] = [ new_question, lsp_client.get_multi_snippet(new_question["workspace_symbol"], 10) ]
                  puts "Queued new Code Question for symbol: #{resolution['workspace_symbol']} (Depth: #{new_depth})"
                else
                  result[:resolved] = {
                    question: current_question["question"],
                    example: current_question["example"],
                    workspace_symbol: current_question["workspace_symbol"],
                    resolved_code: "",
                    commentary: "Max recursion depth reached. " + resolution["commentary"],
                    status: "unresolved"
                  }
                end
              else
                result[:resolved] = {
                  question: current_question["question"],
                  example: current_question["example"],
                  workspace_symbol: current_question["workspace_symbol"],
                  resolved_code: "",
                  commentary: "Unresolved: " + resolution["commentary"],
                  status: "unresolved"
                }
              end
    
              # Return the successfully processed result.
              result
            end
          rescue Timeout::Error => e
            puts "Timeout error processing Code Question: #{current_question['question']} (#{current_question['workspace_symbol']}): #{e.message}"
            "error getting result"
          rescue StandardError => e
            puts "Error processing Code Question: #{current_question['question']} (#{current_question['workspace_symbol']}) - #{e.message}"
            "error getting result"
          end
        end
      end.map(&:value)  # waits for each thread to finish and collects its result.
    
      # Sequentially update shared collections based on the thread results.
      thread_results.each do |res|
        next if res.nil? || res == "error getting result"
        resolved_questions << res[:resolved] if res[:resolved]
        if res[:queued]
          new_question, multi_snippet = res[:queued]
          # Queue the new question in the next depth level.
          question_queues[depth + 1] << [ new_question, multi_snippet ]
        end
      end
    
      depth += 1
    end

    puts "preparing final review...."

    file_result[:code_questions] = resolved_questions
    final_review_results << file_result

    # Build the final resolved code string by including only questions marked as "resolved".
    file_resolved_codes = resolved_questions.select { |rq| rq[:status] == "resolved" }.map do |rq|
      "Question: #{rq[:question]}\nResolved Code:\n#{rq[:resolved_code]}\nCommentary: #{rq[:commentary]}"
    end.join("\n\n===\n\n")

    unresolved_questions = resolved_questions.select { |rq| rq[:status] != "resolved" }.map do |rq|
      "Question: #{rq[:question]}\nCommentary: #{rq[:commentary]}"
    end.join("\n\n===\n\n")

    # If no question was ever resolved, do not include any snippet code.
    final_user_content = if file_resolved_codes.strip.empty?
                           "Here is the file under review:\n\n#{file_content}\n\nNo resolved code snippets were obtained from the Code Search Requests."
                         else
                           "Here is the file under review:\n\n#{file_content}\n\nBelow are the resolved code snippets:\n\n#{file_resolved_codes}\n\nand here are the unresolved questions:\n\n#{unresolved_questions}"
                         end
    

    if MOA == true
      final_review_response = mixture_of_agents_final_review(client, final_user_content, file_content, filepath)
    else 
      final_messages = [
        { 'role' => 'system', 'content' => SYSTEM_PROMPT_FINAL_REVIEW },
        { 'role' => 'user', 'content' => final_user_content + "\n\nPlease provide your final security review." }
      ]
      puts "executing final review..."
      final_review_response = call_chat(client, final_messages)
    end
    

    File.open(OUTPUT_FILE, 'a') do |out_file|
      out_file.puts "Enhanced Security Review Results for File: #{filepath}"
      out_file.puts "=================================="
      out_file.puts "\nFinal Security Review:"
      out_file.puts final_review_response
      out_file.puts "\n==================================\n"
    end

    File.open(QUESTIONS_OUTPUT_FILE, 'a') do |out_file|
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
    end

    puts "Review results for #{filepath} saved to #{OUTPUT_FILE}. Took #{Time.now - start_time} seconds."
  end

  puts "Enhanced security review complete. Results saved to #{OUTPUT_FILE}."
end

puts "Disconnecting LSP client..."
lsp_client.disconnect
