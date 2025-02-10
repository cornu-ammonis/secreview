## Usage

- run LSP server in root directory of app code (e.g. `solargraph socket`)
- optionally run `ruby ./lsp_proxy.rb` (this allows editing and re-running the main review script without re-initializing the LSP server)
    - by default the review script points to the proxy's port, tweak this to point to your LSP as necessary
- run `ruby ./review.rb [project-root-directory]`
- provide a target file or directory to begin review 
- see results in results.txt
