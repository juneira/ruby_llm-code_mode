# frozen_string_literal: true

require "ruby_llm"
require "security_box"

module RubyLLM
  class CodeMode < Tool
    VERSION = "0.4.3"

    DEFAULT_TIMEOUT_MS = 30_000
    DEFAULT_FUEL_MS = 10_000
    MAX_TOOLS = SecurityBox::Rpcs::MAX_RPCS

    TOOL_USAGE = "tools expects RubyLLM::Tool classes or instances, " \
                 'or "name" => tool pairs'

    Mount = Struct.new(:host, :guest, :mode, :description, keyword_init: true) do
      # The hash shape SecurityBox::Configuration.build expects under
      # `mounts:`.
      def payload
        { host: host, guest: guest, mode: mode }
      end
    end

    ToolEntry = Struct.new(:name, :tool, keyword_init: true)

    McpEntry = Struct.new(:name, :mcp, :instructions, keyword_init: true)
  end
end

require_relative "code_mode/description"
require_relative "code_mode/registry"
require_relative "code_mode/dsl"
require_relative "code_mode/instance_methods"
