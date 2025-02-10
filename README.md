## Usage

- run LSP server in root directory of app code (e.g. `solargraph socket`)
- optionally run `ruby ./lsp_proxy.rb` (this allows editing and re-running the main review script without re-initializing the LSP server)
    - by default the review script points to the proxy's port, tweak this to point to your LSP as necessary
- run `ruby ./review.rb [project-root-directory]`
- provide a target file or directory to begin review 
- see results in results.txt


<img width="504" alt="Screenshot 2025-02-09 at 3 40 25 PM" src="https://github.com/user-attachments/assets/3dd5cb04-61fd-4bef-9373-2ed7a2845147" />
