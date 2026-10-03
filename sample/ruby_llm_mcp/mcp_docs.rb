# frozen_string_literal: true

require "bundler/setup"
require_relative "../../lib/ruby_llm/code_mode"

# Microsoft Learn's public MCP server — no authentication required.
# The tool list is fetched from the server on first access.
MCP_DOCS = RubyLLM.mcp(url: "https://learn.microsoft.com/api/mcp")

class DocsResearch < RubyLLM::CodeMode
  # Bind the server; every tool it offers is callable from inside the
  # sandbox by its server name, e.g. SB.call('microsoft_docs_search', query: '...').
  mcp MCP_DOCS
end

RubyLLM.configure do |config|
  config.openrouter_api_key = ENV.fetch("OPENROUTER_API_KEY")
end

puts "Server tools: #{MCP_DOCS.tools.map(&:name).join(', ')}"
puts "Starting..."

chat = RubyLLM.chat(model: "deepseek/deepseek-v4.1-flash", provider: "openrouter")
chat.with_tools(DocsResearch)

chat.before_tool_call do |tool_call|
  puts "Calling tool: #{tool_call.name}"
  puts "Arguments: #{tool_call.arguments}"
  puts "---"
end

response = chat.ask <<~PROMPT
  Use the code_mode tool to research Microsoft documentation.

  1. Search Microsoft Learn for how Azure Blob Storage lifecycle management
     policies work.
  2. Also look up how retention works for Azure Storage queues.
  3. Answer with a short summary that cites the documentation URLs you found.
PROMPT

puts response.content