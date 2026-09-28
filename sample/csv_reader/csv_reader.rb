# frozen_string_literal: true

require "fileutils"
require_relative "../../lib/ruby_llm/code_mode"

SAMPLE_DIR = __dir__

class CsvReader < RubyLLM::CodeMode
  mount    source: File.join(SAMPLE_DIR, "data"),
           dest: "/data",
           description: "Sales CSVs. sales.csv has the columns: date, product, category, units, unit_price"

  mount_rw source: File.join(SAMPLE_DIR, "out"),
           dest: "/workspace",
           description: "Write generated reports and artifacts here"
end

RubyLLM.configure do |config|
  config.openrouter_api_key = ENV.fetch("OPENROUTER_API_KEY")
end

chat = RubyLLM.chat(model: "deepseek/deepseek-v4.1-flash", provider: "openrouter")
chat.with_tools(CsvReader)

response = chat.ask <<~PROMPT
  Use the code_mode tool to analyze the sales data in /data/sales.csv.

  1. Compute the total revenue per category and the best-selling product by units.
  2. Save a short markdown report with those numbers to /workspace/report.md.
  3. Answer with a one-paragraph summary of what you found.
PROMPT

puts response.content
