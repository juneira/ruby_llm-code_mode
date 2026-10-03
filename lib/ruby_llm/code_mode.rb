# frozen_string_literal: true

require "ruby_llm"
require "security_box"

module RubyLLM
  class CodeMode < Tool
    VERSION = "0.1.2"

    DEFAULT_TIMEOUT_MS = 30_000
    DEFAULT_FUEL_MS = 10_000
    MAX_TOOLS = SecurityBox::Rpcs::MAX_RPCS

    TOOL_USAGE = "tool expects a RubyLLM::Tool class or instance, " \
                 'or exactly one "name" => tool pair'

    FIXED_DESCRIPTION = <<~DESC.freeze
      Executes Ruby code inside a secure sandbox and returns what it produced.

      ## How to use

      Pass a complete, self-contained Ruby script as the `code` argument. It runs
      as a fresh Ruby 4.0 process with:
      - no network, no threads, no subprocesses, and no access to the host
        filesystem outside the mounted folders listed below;
      - a private writable scratch directory at `/work`, wiped between executions;
      - no state carried over between executions, except the contents of
        read-write folders.

      Capture progress with `puts` (returned as `stdout`) and end with a value or
      a JSON-serializable data structure (returned as `value`; non-serializable
      objects come back as their inspect string). If the code raises, the error
      class, message and backtrace are returned so you can fix and retry.
    DESC

    HOST_TOOLS_INTRO = <<~DESC.freeze
      Registered host tools are callable from inside the sandbox. Call one with
      `SB.call('name', key: value)`: arguments must be JSON-serializable and become
      the tool's keyword arguments, and the return value is the tool's result
      (non-serializable values come back as their inspect string). Bad arguments
      come back as an `error` hash; handler failures raise `SB::ToolError`
      (rescuable); unknown names raise `SB::UnknownTool`. Limits: at most 1000
      tool calls per execution and 1 MiB per result.
    DESC

    Mount = Struct.new(:host, :guest, :mode, :description, keyword_init: true) do
      def payload
        { host: host, guest: guest, mode: mode }
      end
    end

    ToolEntry = Struct.new(:name, :tool, keyword_init: true)

    McpEntry = Struct.new(:name, :mcp, :instructions, keyword_init: true)

    class << self
      def tool_name
        leaf = name.to_s.split('::').last
        return '' unless leaf

        RubyLLM::Support::Utils.underscore(leaf).delete_suffix('_tool')
      end

      def mount(source:, dest:, description: nil)
        add_mount(source, dest, :read_only, description)
      end

      def mount_rw(source:, dest:, description: nil)
        add_mount(source, dest, :read_write, description)
      end

      def tool(mapping = nil, **kwargs)
        if !kwargs.empty?
          raise ArgumentError, TOOL_USAGE unless kwargs.size == 1 && mapping.nil?

          name, bound = kwargs.first
          mapping = { name.to_s => bound }
        end

        if mapping.is_a?(Hash)
          raise ArgumentError, TOOL_USAGE unless mapping.size == 1

          name, bound = mapping.first
          add_tool(bound, name.to_s)
        else
          add_tool(mapping, nil)
        end
      end

      # Connects MCP server(s) and binds all their tools into the sandbox:
      #
      #   docs = RubyLLM.mcp(url: "https://learn.microsoft.com/api/mcp")
      #
      #   class DocsResearch < RubyLLM::CodeMode
      #     mcp docs                    # instance
      #     mcp MicrosoftDocs           # or the class (instantiated with .new)
      #     mcp Linear, user: current_user  # class + declared inputs
      #     mcp Docs, Github            # several servers / arrays at once
      #   end
      #
      # Server tools keep their names (`microsoft_docs_search`, ...); a tool
      # whose name is already bound is re-bound as "<server>_tool". The
      # servers' instructions (when the server sends them) are snapshotted
      # at definition and listed in the description under "## Server notes".
      # Fails fast: every argument must be a RubyLLM::MCP (class or
      # instance), and if anything goes wrong — a server that cannot be
      # reached, a name that stays colliding after prefixing — nothing is
      # bound.
      def mcp(*servers, **inputs)
        flat = servers.flatten(1)
        raise ArgumentError, "expected at least one RubyLLM::MCP server" if flat.empty?
        unless inputs.empty? || flat.all?(Class)
          raise ArgumentError, "inputs only apply when passing RubyLLM::MCP classes"
        end

        snapshot_tools = tools.dup
        snapshot_mcps = mcps.dup
        normalize_mcp_servers(flat, inputs).each { |server| bind_mcp_server(server) }
        mcps
      rescue StandardError
        instance_variable_set(:@tools, snapshot_tools)
        instance_variable_set(:@mcps, snapshot_mcps)
        raise
      end

      def mounts
        @mounts ||= []
      end

      def tools
        @tools ||= {}
      end

      def mcps
        @mcps ||= []
      end

      def configuration
        @configuration ||= SecurityBox::Configuration.build(
          timeout_ms: DEFAULT_TIMEOUT_MS,
          fuel_ms: DEFAULT_FUEL_MS,
          mounts: mounts.map(&:payload),
          rpcs: build_rpcs
        )
      end

      def build_description
        read_only, read_write = mounts.partition { |m| m.mode == :read_only }
        [
          FIXED_DESCRIPTION.rstrip,
          folder_section("## Read-only folders (readable, never writable)", read_only),
          folder_section("## Read-write folders (readable and writable)", read_write),
          tools_section,
          server_notes_section
        ].compact.join("\n\n")
      end

      def description(text = nil)
        raise ArgumentError,
              "RubyLLM::CodeMode builds the tool description from the declared mounts; " \
              "the description is fixed and cannot be set by hand" if text

        build_description
      end

      def warmup
        SecurityBox.warmup(timeout_ms: DEFAULT_TIMEOUT_MS, fuel_ms: DEFAULT_FUEL_MS)
      end

      def inherited(subclass)
        super
        subclass.instance_variable_set(:@mounts, mounts.dup)
        subclass.instance_variable_set(:@tools, tools.dup)
        subclass.instance_variable_set(:@mcps, mcps.dup)
        subclass.instance_variable_set(:@configuration, nil)
      end

      private

      def add_mount(source, dest, mode, description)
        mounts << Mount.new(
          host: File.expand_path(source.to_s),
          guest: dest.to_s,
          mode: mode,
          description: description.to_s
        )
        SecurityBox::Mounts.normalize(mounts.map(&:payload))
      rescue SecurityBox::InvalidConfiguration => e
        mounts.pop
        raise ArgumentError,
              "Invalid mount #{source.inspect} => #{dest.inspect}: #{e.message}"
      end

      def add_tool(bound, name)
        instance = normalize_bound_tool(bound)
        if instance.is_a?(RubyLLM::CodeMode)
          raise ArgumentError, "cannot bind a RubyLLM::CodeMode inside another CodeMode"
        end

        name = (name || tool_binding_name(instance)).to_s
        raise ArgumentError, "tool name must be a non-empty String" if name.empty?
        raise ArgumentError, "tool name #{name.inspect} is already bound" if tools.key?(name)
        if tools.size >= MAX_TOOLS
          raise ArgumentError, "too many tools (#{tools.size + 1}); the limit is #{MAX_TOOLS}"
        end

        tools[name] = ToolEntry.new(name: name, tool: instance)
      end

      def normalize_bound_tool(bound)
        if bound.is_a?(Class)
          unless bound <= RubyLLM::Tool
            raise ArgumentError, "expected a RubyLLM::Tool (class or instance), got #{bound.inspect}"
          end

          bound.new
        elsif bound.is_a?(RubyLLM::Tool)
          bound
        else
          raise ArgumentError, "expected a RubyLLM::Tool (class or instance), got #{bound.inspect}"
        end
      end

      # Leaf-only name derivation, like .tool_name — the guest has no use
      # for the RubyLLM namespace ("MyApp::Tools::Search" binds as "search").
      def leaf_tool_name(klass)
        leaf = klass.name.to_s.split('::').last
        return "" unless leaf

        RubyLLM::Support::Utils.underscore(leaf).delete_suffix('_tool')
      end

      # Regular tools keep the leaf-only derivation; MCP tools carry their
      # own (server) name, which is what they bind under inside the sandbox.
      def tool_binding_name(instance)
        return instance.name.to_s if instance.respond_to?(:server_name)

        leaf_tool_name(instance.class)
      end

      def build_rpcs
        tools.transform_values { |entry| ->(args) { call_bound_tool(entry, args) } }
      end

      def call_bound_tool(entry, args)
        unless args.is_a?(Hash)
          raise ArgumentError,
                "tool #{entry.name.inspect} expects a hash of arguments, got #{args.class}"
        end

        normalize_result(entry.tool.call(**args))
      end

      # MCP tools return RubyLLM::MCP::Result objects; SecurityBox JSON
      # round-trips handler returns, so give the guest plain data instead
      # of an inspect string.
      def normalize_result(value)
        return value unless defined?(RubyLLM::MCP::Result) && value.is_a?(RubyLLM::MCP::Result)

        { text: value.text, structured: value.structured, error: value.error? }
      end

      def normalize_mcp_servers(servers, inputs)
        unless defined?(RubyLLM::MCP)
          raise ArgumentError,
                "RubyLLM::MCP is not available; mcp needs a ruby_llm version with MCP support"
        end

        servers.map do |server|
          case server
          when Class
            unless server <= RubyLLM::MCP
              raise ArgumentError, "expected a RubyLLM::MCP (class or instance), got #{server.inspect}"
            end

            server.new(**inputs)
          when RubyLLM::MCP
            server
          else
            raise ArgumentError, "expected a RubyLLM::MCP (class or instance), got #{server.inspect}"
          end
        end
      end

      def bind_mcp_server(server)
        # Fetching .tools connects to the server; snapshot the instructions
        # right after, so description builds never touch the network.
        tools_list = server.tools
        mcps << McpEntry.new(
          name: server.name.to_s, mcp: server, instructions: server.instructions.to_s
        )
        tools_list.each { |tool| bind_mcp_tool(server, tool) }
      end

      def bind_mcp_tool(server, tool)
        name = tool_binding_name(tool)
        name = "#{server.name}_#{name}" if tools.key?(name) && !server.name.to_s.empty?
        add_tool(tool, name)
      end

      def folder_section(header, entries)
        return nil if entries.empty?

        lines = entries.map do |entry|
          line = "- `#{entry.guest}`"
          line += " — #{entry.description}" unless entry.description.empty?
          line
        end
        [header, *lines].join("\n")
      end

      def tools_section
        return nil if tools.empty?

        [
          "## Host tools (call with SB.call)",
          HOST_TOOLS_INTRO.rstrip,
          *tools.values.flat_map { |entry| tool_lines(entry) }
        ].join("\n")
      end

      def server_notes_section
        notes = mcps.filter_map do |entry|
          instructions = entry.instructions.to_s
          next if instructions.empty?

          "- **#{entry.name}** — #{instructions}"
        end
        return nil if notes.empty?

        ["## Server notes", *notes].join("\n")
      end

      def tool_lines(entry)
        line = "- `#{entry.name}`"
        description = entry.tool.description.to_s
        line += " — #{description}" unless description.empty?

        [line, *param_lines(entry.tool).map { |param| "  #{param}" }]
      end

      def param_lines(tool)
        schema = tool.parameters_schema || {}
        properties = schema["properties"] || {}
        required = schema["required"] || []

        properties.filter_map do |param, spec|
          spec ||= {}
          status = required.include?(param) ? "required" : "optional"
          line = "- `#{param}` (#{spec["type"] || "string"}, #{status})"
          description = spec["description"].to_s
          line += " — #{description}" unless description.empty?
          line
        end
      end
    end

    parameter :code, description: "Complete Ruby script to execute in the sandbox"

    def execute(code:)
      format_result(sandbox.eval(code))
    rescue SecurityBox::Error => e
      { status: "sandbox_error", error: { class: e.class.name, message: e.message } }
    end

    private

    def sandbox
      @sandbox ||= SecurityBox::Sandbox.new(self.class.configuration)
    end

    def format_result(result)
      payload = { status: result.status.to_s }
      case result.status
      when :ok
        payload[:value] = result.value
      when :error
        payload[:error] = result.error || { "class" => "Unknown", "message" => "guest code failed" }
      when :timeout
        payload[:error] = "execution timed out before finishing"
      when :fuel_exhausted
        payload[:error] = "execution exceeded its CPU budget before finishing"
      when :memory_limit
        payload[:error] = "execution exceeded the sandbox memory limit"
      when :sandbox_error
        payload[:error] = "the sandbox failed to run the code"
      end
      payload[:stdout] = result.stdout if result.stdout && !result.stdout.empty?
      payload[:stderr] = result.stderr if result.stderr && !result.stderr.empty?
      payload
    end
  end
end
