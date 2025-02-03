# !/usr/bin/env ruby
# process_files.rb

require 'openai'
require 'find'

# Constants – adjust these as needed.
SYSTEM_PROMPT = "Can you identify any security issues in this code? Consider that both false negatives (any) and false positives (excessive) are problematic. If you point out a bunch of incorrect/non-issue problems to avoid any possibility of false negatives, this won't be usable. You don't need to list some number of items every time; sometimes the correct answer is that there are no issues or just one or two potential issues. But other times there will be more issues. If you miss key security issues, that is a severe failure case. We particularly care about things that could affect sessions, cross-account security, SQL injection, or compromise server integrity, as well as other Rails application security best practices. It is OK to mention issues that we might deliberately be allowing, so that we can verify. Please don't include a preamble framing what the concerns are in aggregate: just dive right into the list and frame individual concerns as needed.  Thanks and think carefully." # <-- Your system prompt goes here.
MODEL         = 'o3-mini' # or any other model you want to use.
OUTPUT_FILE   = 'results.txt'

# Create an OpenAI client. Ensure your API key is set in the environment.
client = OpenAI::Client.new(access_token: ENV.fetch('OPENAI_API_KEY'))

# Check that the script received a command line argument (file or directory).
if ARGV.empty?
  puts 'Usage: ruby process_files.rb <file_or_directory_path>'
  exit 1
end

input_path = ARGV[0]
puts SYSTEM_PROMPT

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

# Open the output file in append mode.
File.open(OUTPUT_FILE, 'a') do |out_file|
  files.each do |filepath|
    puts "Processing #{filepath}..."
    begin
      file_content = File.read(filepath)
    rescue StandardError => e
      puts "Error reading file #{filepath}: #{e.message}"
      next
    end

    # Prepare the conversation with a system and a user message.
    messages = [
      { 'role' => 'system', 'content' => SYSTEM_PROMPT },
      { 'role' => 'user',   'content' => file_content }
    ]

    # Send the request to the OpenAI API.
    begin
      response = client.chat(
        parameters: {
          model: MODEL,
          messages:,
          reasoning_effort: 'high'
        }
      )

      # Fetch the output from the first choice.
      output_text = response.dig('choices', 0, 'message', 'content')
      output_text = '[No output returned]' if output_text.nil?

      # messages << { "role" => "assistant", "content" => output_text }
      # messages << { "role" => "user", "content" => "Thanks for your review. Can you double check the file in light if your first review, and make sure you didn't miss anything serious? Do not repeat or summarize what's already said, if there's nothing else, just say that, or list additional concerns if you have them." }

      # puts "2nd look at #{filepath}..."
      # response2 = client.chat(
      #   parameters: {
      #     model: MODEL,
      #     messages: messages,
      #     reasoning_effort: 'high'
      #   }
      # )

      # output_text2 = response2.dig("choices", 0, "message", "content")

      # Append the results to the output file.
      out_file.puts "File: #{filepath}"
      out_file.puts 'Response:'
      out_file.puts output_text
      # out_file.puts "2nd look:"
      # out_file.puts output_text2
      out_file.puts '------------------------------------------------------------'
      out_file.flush

      puts "Finished processing #{filepath}."
    rescue StandardError => e
      puts "Error processing file #{filepath}: #{e.message}"
      next
    end
  end
end
