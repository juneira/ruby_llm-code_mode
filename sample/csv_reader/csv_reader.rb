# frozen_string_literal: true

require "fileutils"
require_relative "../../lib/ruby_llm/code_mode"

SAMPLE_DIR = __dir__

class SalesNotes < RubyLLM::Tool
  description "Saves a short note to the host project's notes log. Use it to " \
              "record interesting findings while you analyze the data."

  parameter :note, type: "string", description: "The note text"

  def execute(note:)
    puts "CALL NOTE!!!"
    path = File.join(SAMPLE_DIR, "out", "notes.log")
    FileUtils.mkdir_p(File.dirname(path))
    File.open(path, "a") { |file| file.puts "- #{note}" }
    { status: "saved" }
  end
end

class CsvReader < RubyLLM::CodeMode
  mount    source: File.join(SAMPLE_DIR, "data"),
           dest: "/data",
           description: "Sales CSVs. sales.csv has the columns: date, product, category, units, unit_price"

  mount_rw source: File.join(SAMPLE_DIR, "out"),
           dest: "/workspace",
           description: "Write generated reports and artifacts here"

  tool SalesNotes
end

RubyLLM.configure do |config|
  config.openrouter_api_key = ENV.fetch("OPENROUTER_API_KEY")
end

chat = RubyLLM.chat(model: "deepseek/deepseek-v4.1-flash", provider: "openrouter")
chat.with_tools(CsvReader)

puts "Starting..."
chat.before_tool_call do |tool_call|
  puts "Calling tool: #{tool_call.name}"
  puts "Arguments: #{tool_call.arguments}"
  puts "---"
end

response = chat.ask <<~PROMPT
  Use the code_mode tool to analyze the sales data in /data/sales.csv.

  1. Compute the total revenue per category and the best-selling product by units.
  2. Save a short markdown report with those numbers to /workspace/report.md.
  3. Record the single most interesting finding with the sales_notes host tool.
  4. Answer with a one-paragraph summary of what you found.
PROMPT

puts response.content
