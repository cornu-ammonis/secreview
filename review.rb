#!/usr/bin/env ruby

require 'openai'
require 'json'
require 'find'
require 'net/http'
require 'json'
require 'uri'
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
Act as a hyper-vigilant security code reviewer for Ruby on Rails applications. You possess a "security-paranoid" mindset that allows you to:
- Detect subtle vulnerabilities that others might overlook
- Identify potential attack chains and multi-step exploitation paths
- Anticipate how seemingly innocent code could be manipulated in unexpected ways
- Consider edge cases and uncommon execution paths

When reviewing the provided Rails file and associated code snippets:
1. Scrutinize the code with extreme skepticism
2. Question assumptions about input validation, authentication, and authorization
3. Consider how the code might behave under adversarial conditions
4. Look for subtle interactions between components that could create emergent vulnerabilities

For each identified issue, include an explicit likelihood assessment (Highly Likely, Possible, Theoretical) to help downstream decision-makers prioritize effectively.

Structure your response as follows:

## ISSUES
* Critical vulnerabilities with concrete exploitation paths
* Include: vulnerability type, affected code, exploitation scenario, and likelihood assessment
* Briefly suggest conceptual remediation approaches
* If none found, state "No critical security issues identified"

## CONCERNS
* Suspicious patterns, edge cases, and theoretical attack vectors
* Include likelihood assessments and potential impact if exploited
* Focus on concerns with realistic attack scenarios, not purely theoretical weaknesses

## COMMENTARY
* Address subtle security design patterns in the codebase
* Note any environmental factors or deployment considerations that could affect security
* Identify implicit trust relationships that might be exploitable

While being thorough and vigilant, prioritize meaningful analysis over purely theoretical edge cases. Your goal is to uncover real but subtle security issues, not to overwhelm with every conceivable scenario.
PROMPT

SYSTEM_PROMPT_JUSTIFIER = <<~PROMPT
Act as a senior principal engineer for Ruby on Rails applications who specializes in contextual security assessment. You excel at:
- Distinguishing between theoretical and practical security concerns
- Providing evidence-based explanations for why potential issues may not be actual vulnerabilities
- Recognizing when deviations from Rails conventions actually present security risks
- Balancing security considerations with practical engineering judgments

When reviewing the provided Rails code and associated snippets:
1. Evaluate potential security concerns with contextual understanding of Rails security models
2. Consider implementation details that might mitigate apparent vulnerabilities
3. Identify when more information would be needed to confirm or dismiss a concern
4. Recognize user-facing reliability issues that might indirectly impact security

Structure your response as follows:

## ISSUES
* Confirmed vulnerabilities or reliability problems requiring attention
* Include: issue type, affected code location, and concrete impact assessment
* Briefly suggest remediation approaches grounded in Rails best practices
* If none found, state "No security or reliability issues identified"

## CONCERNS ADDRESSED
* Potential issues that deeper analysis reveals are not actual vulnerabilities
* For each: describe the apparent concern, then provide evidence-based reasoning for why it's not exploitable
* Reference specific code patterns, Rails security mechanisms, or architectural factors that mitigate the concern

## COMMENTARY
* Note interesting implementation choices with security implications
* Highlight areas where additional context or testing would provide greater confidence
* Suggest refinements that would improve security posture while maintaining functionality

Your goal is to provide nuanced, evidence-based security analysis that reduces false positives while still identifying genuine issues. Focus on what matters rather than theoretical edge cases.
PROMPT

SYSTEM_PROMPT_GENERIC = <<~PROMPT
Act as an expert security code reviewer for Ruby on Rails applications.

Review the provided Rails file and associated code snippets with a security-focused perspective. You'll receive:
- The main file for review
- Related code snippets providing additional context
- A list of both resolved and unresolved code search questions

While these questions highlight areas of interest, conduct a comprehensive security review that may identify issues beyond these focus areas.

Structure your response as follows:

## ISSUES
* Critical security vulnerabilities requiring immediate attention
* Include: vulnerability type, affected code location, and potential impact
* For each, briefly suggest a conceptual approach to remediation
* If none found, state "No critical security issues identified"

## CONCERNS
* Moderate-risk items or security code smells
* Include specific code references and general mitigation strategies
* Limit to meaningful concerns to avoid creating noise

## COMMENTARY
* Overall security assessment of the code
* Any patterns or architectural considerations affecting security

Balance thoroughness with practicality - avoid both missing critical vulnerabilities and overwhelming with minor issues.
PROMPT

SYSTEM_PROMPT_PRINCIPAL = <<~PROMPT
Act as a principal-level security engineer conducting the final consolidated security review of a Ruby on Rails application. You possess expert knowledge of Rails security vulnerabilities and strategic judgment.

You'll analyze three types of inputs:
1. Multiple security reviews from different reviewers (each containing their own ISSUES, CONCERNS, and COMMENTARY)
2. Related code snippets gathered during an earlier code lookup phase (which may provide context or implementation details relevant to the current file under review)
3. The original application code under review

Your task is to:
- Synthesize findings across all reviewer inputs, identifying consensus and resolving conflicting opinions
- Consider the related code snippets as additional context that may help confirm or dismiss potential security concerns
- Conduct your own independent assessment of the original code to identify any overlooked vulnerabilities
- Exercise judgment in determining which issues truly warrant attention versus which are less impactful

Format your response with these clearly delineated sections:

## ISSUES
* List critical security vulnerabilities that must be addressed before deployment
* For each, include: vulnerability name, affected code location, potential impact, and a conceptual approach to remediation (not full code solutions)
* Note whether the issue was identified by specific reviewers or discovered in your analysis
* If relevant, reference how the additional code snippets informed your assessment
* If none found, state "No critical security issues identified"

## CONCERNS
* List moderate-risk items or edge cases that warrant attention but aren't deployment blockers
* Include specific code references and general mitigation strategies
* Indicate the source of each concern (specific reviewers or your analysis)
* Where applicable, explain how the related code snippets provided additional context
* Limit to the most important concerns to avoid creating noise

## COMMENTARY
* Provide holistic assessment of the application's security posture
* Address significant points or patterns across reviewer inputs
* Note how the related code implementations influenced your overall assessment
* Offer architectural or systematic recommendations to improve security

Balance thoroughness with practicality - both missing critical vulnerabilities and overwhelming stakeholders with minor issues are equally problematic in a security review.
PROMPT

SYSTEM_PROMPT_PRINCIPAL_NO_CONTEXT = <<~PROMPT
Act as a principal-level security engineer conducting a comprehensive security review of Ruby on Rails application code. You possess expert knowledge of Rails security vulnerabilities, data protection requirements, and secure coding practices.

Your task is to:
- Thoroughly analyze the provided application code for security vulnerabilities
- Prioritize issues that could lead to customer data exposure or compromise
- Apply strategic judgment to distinguish between critical, moderate, and minor concerns
- Focus on identifying high-impact security problems without getting distracted by trivial issues

Format your response with these clearly delineated sections:

## ISSUES
* List critical security vulnerabilities that present significant risk to the application or customer data
* For each, include: vulnerability type, affected code location, and potential impact, suggested improvement (not full code)
* If none found, state "No critical security issues identified"

## CONCERNS
* List moderate-risk vulnerabilities or security anti-patterns that warrant attention
* Include specific code references and suggested improvements
* Focus on meaningful concerns rather than theoretical edge cases

## COMMENTARY
* Provide overall assessment of the codebase's security posture
* Note any architectural or systemic patterns that affect security
* Suggest general security improvements if applicable

In this review phase, prioritize identifying all legitimate security risks, particularly those affecting customer data protection. While false positives should be minimized, it's more important to ensure no significant vulnerabilities are overlooked. Less critical issues can be filtered in subsequent reviews.
PROMPT

PARALLEL_AGENT_PROMPTS = [SYSTEM_PROMPT_PARANOID, SYSTEM_PROMPT_JUSTIFIER, SYSTEM_PROMPT_GENERIC, SYSTEM_PROMPT_PRINCIPAL_NO_CONTEXT]

PARALLEL_AGENTS = [
  {prompt: SYSTEM_PROMPT_PARANOID, name: "Paranoid", context: true}, 
  {prompt: SYSTEM_PROMPT_JUSTIFIER, name: "Justifier", context: true}, 
  {prompt: SYSTEM_PROMPT_GENERIC, name: "Generic", context: true},
  {prompt: SYSTEM_PROMPT_PRINCIPAL_NO_CONTEXT, name: "No context", context: false},
  {prompt: SYSTEM_PROMPT_PRINCIPAL_NO_CONTEXT, name: "No context sonnet", context: false, model: :sonnet},
  {prompt: SYSTEM_PROMPT_GENERIC, name: "Generic sonnet", context: true, model: :sonnet},
  {prompt: SYSTEM_PROMPT_PARANOID, name: "Paranoid sonnet", context: true, model: :sonnet}, 
  {prompt: SYSTEM_PROMPT_JUSTIFIER, name: "Justifier sonnet", context: true, model: :sonnet}, 
]

MODEL       = 'o3-mini'
OUTPUT_FILE = 'results.md'
AGENT_OUTPUT_FILE = 'agent_results.txt'
QUESTIONS_OUTPUT_FILE = 'questions.txt'

SONNET_API_URL = 'http://localhost:9292/v1/messages'

def sonnet_thinking_response(system, prompt, max_retries = 2)
  uri = URI(SONNET_API_URL)
  http = Net::HTTP.new(uri.host, uri.port)
  
  # Set SSL if the API is using HTTPS
  http.use_ssl = (uri.scheme == 'https')
  
  # Configure longer timeouts (in seconds)
  http.open_timeout = 30  # Time to open the connection
  http.read_timeout = 150 # Time to read the response (2.5 minutes)
  
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
    max_tokens: 20000,
    system: [type: "text", text: system, "cache_control": {"type": "ephemeral"} ] ,
    thinking: { type: 'enabled', budget_tokens: 8000},
    stream: false 
  }.to_json
  
  retries = 0
  begin
    response = http.request(request)
    
    if response.code.to_i == 200
      result = JSON.parse(response.body)
      puts result.dig('usage')
      # Extract the text content from the complete response
      return result.dig('content', 1, 'text')
    else
      puts "Error: #{response.code} - #{response.body}"
      return nil
    end
  rescue Net::ReadTimeout => e
    retries += 1
    if retries <= max_retries
      puts "Timeout occurred (attempt #{retries}/#{max_retries}). Retrying..."
      retry
    else
      puts "Failed after #{max_retries} attempts: #{e.message}"
      return nil
    end
  rescue StandardError => e
    puts "Error occurred: #{e.class} - #{e.message}"
    return nil
  end
end

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

def mixture_of_agents_final_review(client, code_inputs, original_file, filepath)
  threads = PARALLEL_AGENTS.map do |agent|
    Thread.new do
      prompt = agent[:prompt]
      content = if agent[:context] == false
        # the idea here is to have one agent operate on only the original file, to mitigate 
        # the effect of becoming distracted by the resolved/unresolved questions and missing issues
        # that are clear from the original file alone.
        puts "executing this agent on original file in isolation..."
        original_file
      else
        puts "executing agent..."
        code_inputs
      end

      model_response = if agent[:model] == :sonnet
        sonnet_thinking_response(prompt, content)
      else
        messages = [
          { role: "system", content: prompt },
          { role: "user", content: content }
        ]
        call_chat(client, messages, reasoning_effort: 'high')
      end

      "Reviewer: #{agent[:name]}\n" + model_response unless model_response.nil?
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

  final_message_content = multi_agent_result + "\n\n" + code_inputs + "\n\nPlease provide your final security review."
  
  "Sonnet response: \n\n" + (sonnet_thinking_response(SYSTEM_PROMPT_PRINCIPAL, final_message_content) || "")
end

# Generates initial code questions (CSRs) for a file's content.
def generate_code_questions(client, file_content)
  messages = [
    { 'role' => 'system', 'content' => SYSTEM_PROMPT_QUESTIONS },
    { 'role' => 'user',
      'content' => "Please analyze the following Ruby code and output any Code Search Requests (CSRs) as described. Include for each CSR a 'question', an 'example', and a 'workspace_symbol'. Do not include any extra text - only output valid JSON.\n\n#{file_content}" }
  ]
  response_text = call_chat(client, messages, reasoning_effort: 'medium')
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
                           "Here are the resolved code snippets:\n\n#{file_resolved_codes}\n\nand here are the unresolved questions:\n\n#{unresolved_questions} \n\n Here is the file under review:\n\n#{file_content}"
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
