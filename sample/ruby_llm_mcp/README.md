# ruby_llm_mcp sample

End-to-end example of connecting a [RubyLLM::MCP](https://rubyllm.com/next/mcp/)
server to a `RubyLLM::CodeMode` sandbox with the `mcp` DSL, so the model can
call the server's tools from inside sandboxed Ruby code with `SB.call`.

The server is Microsoft Learn's public MCP endpoint
(`https://learn.microsoft.com/api/mcp`) — no authentication required.

## Setup

RubyLLM::MCP is not on RubyGems yet, so this sample points the Gemfile at a
local clone of the `ruby_llm` repository (expected at
`../../ruby_llm` relative to this folder — adjust the `gem "ruby_llm", path:`
line if your clone lives elsewhere).

```bash
cd sample/ruby_llm_mcp
bundle install
OPENROUTER_API_KEY=... bundle exec ruby mcp_docs.rb
```

To test the wiring without spending LLM tokens (connects, binds, and calls
`microsoft_docs_search` directly through the host RPC handler):

```bash
bundle exec ruby dry_run.rb
```

## What happens

1. `RubyLLM.mcp(url:)` builds an inline MCP client for Microsoft Learn.
2. `DocsResearch.mcp MCP_DOCS` connects the server and binds every tool it
   offers; each tool keeps its server name (`microsoft_docs_search`, ...) and
   its JSON schema is rendered into the tool description.
3. The model writes Ruby in the sandbox like:

   ```ruby
   result = SB.call("microsoft_docs_search", query: "Azure Blob Storage lifecycle management")
   result[:text] # => "..."
   ```

4. Each `SB.call` reaches the host and performs the MCP request over HTTP —
   the sandbox itself never sees the network.