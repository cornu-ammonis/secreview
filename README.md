# SecReview - Ruby on Rails Security Code Review Tool

SecReview is a tool for automated security code review of Ruby on Rails applications. It uses the Language Server Protocol (LSP) and OpenAI API to analyze code, identify potential security issues, and provide detailed reports.

## Features

- Automated security code review for Ruby on Rails applications
- Integration with LSP for advanced code analysis
- Recursive code exploration based on detected security concerns
- Mixture-of-Agents approach for diverse security perspectives
- Detailed reporting on security issues, concerns, and commentary

## Requirements

- Ruby 2.7+
- Solargraph (or compatible LSP server)
- OpenAI API key

## Installation

1. Clone the repository:
   ```
   git clone https://github.com/yourusername/secreview.git
   cd secreview
   ```

2. Install dependencies:
   ```
   bundle install
   ```

3. Set your OpenAI API key:
   ```
   export OPENAI_API_KEY=your-api-key
   ```

## Usage

- Run LSP server in root directory of app code (e.g. `solargraph socket`)
- Optionally run `ruby ./lsp_proxy.rb` (this allows editing and re-running the main review script without re-initializing the LSP server)
    - by default the review script points to the proxy's port, tweak this to point to your LSP as necessary
- Run `ruby ./review.rb [project-root-directory]`
- Provide a target file or directory to begin review 
- See results in `results.txt`, additional details in `agent_results.txt` and `questions.txt`

## Example Output

<img width="504" alt="Screenshot 2025-02-09 at 3 40 25 PM" src="https://github.com/user-attachments/assets/3dd5cb04-61fd-4bef-9373-2ed7a2845147" />

## Configuration

You can configure the behavior of the tool by modifying the constants in `review.rb`:

- `MAX_TOTAL_QUESTIONS`: Maximum number of code questions to process
- `MAX_DEPTH`: Maximum recursion depth for related code exploration
- `MOA`: Enable/disable Mixture-of-Agents approach
- `MODEL`: OpenAI model to use for code review
- Various output file paths and system prompts can also be customized

## License

[MIT License](LICENSE)