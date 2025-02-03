#!/usr/bin/env ruby
# enhanced_process_files.rb

require 'openai'
require 'find'
require 'json'
require 'shellwords' # Needed for safely escaping shell parameters

# CONSTANTS – adjust these as needed.
# SYSTEM_PROMPT includes instructions for generating Code Questions (CQs).
SYSTEM_PROMPT = "You are a security code reviewer for Ruby applications. For each file you are given, if you detect a potential security issue that might depend on code elsewhere in the codebase, generate a Code Question (CQ). Each CQ must include:
1. \"question\": A clear explanation of the security concern (with logical rationale and impact).
2. \"example\": An excerpt from the provided file that raised the concern.
3. \"regex\": A Ruby regular expression that can be used to locate related code (for example, a method definition).
Return only a JSON array of objects with these three keys. If there are no applicable issues, return an empty JSON array

After we resolve the code for your code questions, you will need to do a final review on the file.
List any additional security concerns that you observe (no longer JSON format, use markdown or bullets). If code questions are unresolved, flag them, but you still must provide a final analysis and also analyze things that did not involved code questions.
Consider that both serious false negatives and excessive false positives are problematic; too many concerns and it's noise, but missing a serious Rails application security issue could have dire consequences. Please thank carefully and thanks!
"

FINAL_REVIEW_PROMPT = 'Based on the following code snippets (extracted as resolving some of the Code Questions), please perform a final review of the security posture of the code.'

MODEL         = 'o3-mini' # Change this to the model you want to use.
OUTPUT_FILE   = 'results.txt'

# Create an OpenAI client; ensure your API key is set in the environment.
client = OpenAI::Client.new(access_token: ENV.fetch('OPENAI_API_KEY'))

# Determine input path and the codebase root.
if ARGV.empty?
  puts 'Usage: ruby enhanced_process_files.rb <file_or_directory_path>'
  exit 1
end

input_path = ARGV[0]
codebase_root_arg = ARGV[1]
codebase_root = File.directory?(codebase_root_arg) ? codebase_root_arg : File.dirname(codebase_root_arg)

# Gather all files (if a directory, search recursively; if a file, process it alone).
files = []
if File.directory?(input_path)
  Find.find(input_path) do |path|
    files << path if File.file?(path)
  end
elsif File.file?(input_path)
  files << input_path
else
  puts 'The specified path is not a file or directory.'
  exit 1
end

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
    { 'role' => 'system', 'content' => SYSTEM_PROMPT },
    { 'role' => 'user',
      'content' => "Please analyze the following Ruby code and output any Code Questions (CQs) as described. Include for each CQ a 'question', an 'example', and a 'regex'. Do not include any extra text - only output valid JSON.\n\n#{file_content}" }
  ]
  response_text = call_chat(client, messages, reasoning_effort: 'medium')
  begin
    cq_array = JSON.parse(response_text)
    # Validate that we have an array of objects with all required keys.
    return [] unless cq_array.is_a?(Array)

      cq_array.select do |cq|
        cq.is_a?(Hash) && cq.key?('question') && cq.key?('example') && cq.key?('regex')
      end
  rescue JSON::ParserError => e
    puts "Error parsing Code Questions JSON: #{e.message}"
    []
  end
end

# Helper: Search the codebase using a grep command instead of opening every file.
def search_files_by_regex(codebase_root, regex_str)
  # Escape the regex and the codebase_root to prevent shell issues.
  escaped_regex = Shellwords.escape(regex_str)
  escaped_path  = Shellwords.escape(codebase_root)
  # Construct the grep command: -r to search recursively, -l to list only file names, -E for extended regex.
  command = "grep -rEl #{escaped_regex} #{escaped_path}"
  # Execute the grep command.
  output = `#{command}`
  output.split("\n")
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
    puts "trying cq #{i}"
    cq_result = { question: cq['question'], example: cq['example'], regex: cq['regex'], status: 'unresolved',
                  resolved_snippet: nil }

    # Use the provided regex to search the codebase using grep.
    matching_files = search_files_by_regex(codebase_root, cq['regex'])
    if matching_files.empty?
      puts "no matching files for cq #{i}"
      cq_result[:status] = 'unresolved (no matching files found)'
      file_result[:cqs] << cq_result
      next
    end

    puts "asking for file choice"

    # Ask the model to decide which file from the list to use.
    files_list_str = matching_files.join("\n")
    decision_prompt = "For the Code Question:\n\"#{cq['question']}\"\nI searched the codebase using your regex (#{cq['regex']}) and found these files:\n#{files_list_str}\nPlease respond with the single file path (from the list above) which best contains the code resolving this question. If none of these files are applicable, please reply with 'none'."
    decision_messages = [
      { 'role' => 'system', 'content' => SYSTEM_PROMPT },
      { 'role' => 'user', 'content' => decision_prompt }
    ]
    decision_response = call_chat(client, decision_messages)
    chosen_file = decision_response ? decision_response.strip : ''


    if chosen_file.downcase == 'none' || !matching_files.include?(chosen_file)
      puts "no chosenfile for cq #{i}"
      cq_result[:status] = 'unresolved (model did not select a valid file)'
      file_result[:cqs] << cq_result
      next
    end
    puts "chosen file for cq #{i} is #{chosen_file.downcase}"

    # Read the chosen file's content.
    begin
      chosen_file_content = File.read(chosen_file)
    rescue StandardError => e
      puts "Error reading file #{chosen_file}: #{e.message}"
      cq_result[:status] = 'unresolved (error reading chosen file)'
      file_result[:cqs] << cq_result
      next
    end

    puts "extracting code snippet"
    # Ask the model to extract the snippet that resolves the CQ.
    extraction_prompt = "The following is the content of the file #{chosen_file}:\n\n#{chosen_file_content}\n\nFor the Code Question:\n\"#{cq['question']}\"\nPlease extract and provide the snippet of code (or the full file, if necessary) that resolves the security concern. If you cannot determine a relevant snippet, simply reply with 'none'."
    extraction_messages = [
      { 'role' => 'system', 'content' => SYSTEM_PROMPT },
      { 'role' => 'user', 'content' => extraction_prompt }
    ]
    snippet_response = call_chat(client, extraction_messages, reasoning_effort: 'medium')
    snippet = snippet_response ? snippet_response.strip : ''

    if snippet.downcase == 'none' || snippet.empty?
      cq_result[:status] = 'unresolved (no snippet extracted)'
    else
      cq_result[:status] = 'resolved'
      cq_result[:resolved_snippet] = snippet
      all_resolved_snippets << snippet
    end

    file_result[:cqs] << cq_result
  end

  final_review_results << file_result

  # Now perform a final review using all the resolved code snippets.
  final_snippets_text = all_resolved_snippets.join("\n\n===\n\n")
  final_messages = [
    { 'role' => 'system', 'content' => SYSTEM_PROMPT },
    { 'role' => 'user',
      'content' => "Here is the file under review: \n\n #{file_content}\n\n\nBelow are the code snippets that were extracted as resolving some of the Code Questions:\n\n#{final_snippets_text}\n\n#{FINAL_REVIEW_PROMPT}" }
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
        out_file.puts "Regex: #{cq[:regex]}"
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
