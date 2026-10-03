# frozen_string_literal: true

# Dry run: connect to the server, bind its tools, and call one directly
# through the host RPC handler — no sandbox, no LLM, no tokens spent.
require "bundler/setup"
require_relative "../../lib/ruby_llm/code_mode"

MCP_DOCS = RubyLLM.mcp(url: "https://learn.microsoft.com/api/mcp")

class DocsResearch < RubyLLM::CodeMode
  mcp MCP_DOCS
end

puts "Bound tools: #{DocsResearch.tools.keys.join(', ')}"
puts "---"

result = DocsResearch.configuration.rpcs["microsoft_docs_search"]
        .call({ "query" => "Azure Blob Storage lifecycle management", "max_results" => 2 })

puts "status keys: #{result.keys.inspect}"
puts "error?: #{result[:error]}"
puts "results: #{result[:structured]['results'].map { |r| r['title'] }.inspect}"