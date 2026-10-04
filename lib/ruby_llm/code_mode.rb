# frozen_string_literal: true

require "ruby_llm"
require "security_box"

module RubyLLM
  class CodeMode < Tool
    VERSION = "0.4.0"

    DEFAULT_TIMEOUT_MS = 30_000
    DEFAULT_FUEL_MS = 10_000
    MAX_TOOLS = SecurityBox::Rpcs::MAX_RPCS

    TOOL_USAGE = "tools expects RubyLLM::Tool classes or instances, " \
                 'or "name" => tool pairs'

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

    # Shared registration and rendering core, parameterized by the target
    # collections: the class-level DSL (tools/mcps) and the instance-level API
    # (add_tools/add_mcps) run the exact same validation and rollback logic,
    # only over different hashes/arrays.
    module Registry
      EMPTY = {}.freeze

      class << self
        # Binds tools into `target` (a name => ToolEntry hash). Accepts tool
        # classes/instances, arrays of them, and "name" => tool pairs (hash
        # arguments or kwargs). All-or-nothing: on any failure `target` is
        # restored and the error re-raised. `reserved` lists names already
        # taken elsewhere (e.g. the class-level bindings for instance
        # additions); duplicates against it raise.
        def register_tools(target, args, kwargs, reserved: EMPTY)
          snapshot = target.dup
          begin
            args.flatten(1).each do |item|
              if item.is_a?(Hash)
                item.each { |name, bound| add_tool(target, bound, name.to_s, reserved) }
              else
                add_tool(target, item, nil, reserved)
              end
            end
            kwargs.each { |name, bound| add_tool(target, bound, name.to_s, reserved) }
          rescue StandardError
            target.replace(snapshot)
            raise
          end
          target
        end

        # Connects MCP server(s) and binds all their tools into
        # `target_tools`/`target_mcps`. All-or-nothing across both
        # collections.
        def register_mcps(target_tools, target_mcps, servers, inputs, reserved: EMPTY)
          snapshot_tools = target_tools.dup
          snapshot_mcps = target_mcps.dup
          flat = servers.flatten(1)
          raise ArgumentError, "expected at least one RubyLLM::MCP server" if flat.empty?
          unless inputs.empty? || flat.all?(Class)
            raise ArgumentError, "inputs only apply when passing RubyLLM::MCP classes"
          end

          normalize_mcp_servers(flat, inputs).each do |server|
            bind_mcp_server(target_tools, target_mcps, server, reserved)
          end
          target_mcps
        rescue StandardError
          target_tools.replace(snapshot_tools)
          target_mcps.replace(snapshot_mcps)
          raise
        end

        def rpc_handlers(tools)
          tools.transform_values { |entry| ->(args) { call_bound_tool(entry, args) } }
        end

        def tools_section(tools)
          return nil if tools.empty?

          [
            "## Host tools (call with SB.call)",
            HOST_TOOLS_INTRO.rstrip,
            *tools.values.flat_map { |entry| tool_lines(entry) }
          ].join("\n")
        end

        def server_notes_section(mcps)
          notes = mcps.filter_map do |entry|
            instructions = entry.instructions.to_s
            next if instructions.empty?

            "- **#{entry.name}** — #{instructions}"
          end
          return nil if notes.empty?

          ["## Server notes", *notes].join("\n")
        end

        private

        def add_tool(target, bound, name, reserved)
          instance = normalize_bound_tool(bound)
          if instance.is_a?(RubyLLM::CodeMode)
            raise ArgumentError, "cannot bind a RubyLLM::CodeMode inside another CodeMode"
          end

          name = (name || tool_binding_name(instance)).to_s
          raise ArgumentError, "tool name must be a non-empty String" if name.empty?
          if target.key?(name) || reserved.key?(name)
            raise ArgumentError, "tool name #{name.inspect} is already bound"
          end
          total = target.size + reserved.size
          if total >= MAX_TOOLS
            raise ArgumentError, "too many tools (#{total + 1}); the limit is #{MAX_TOOLS}"
          end

          target[name] = ToolEntry.new(name: name, tool: instance)
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
                  "RubyLLM::MCP is not available; mcps needs a ruby_llm version with MCP support"
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

        def bind_mcp_server(target_tools, target_mcps, server, reserved)
          # Fetching .tools connects to the server; snapshot the instructions
          # right after, so description builds never touch the network.
          tools_list = server.tools
          target_mcps << McpEntry.new(
            name: server.name.to_s, mcp: server, instructions: server.instructions.to_s
          )
          tools_list.each { |tool| bind_mcp_tool(target_tools, server, tool, reserved) }
        end

        def bind_mcp_tool(target_tools, server, tool, reserved)
          name = tool_binding_name(tool)
          if (target_tools.key?(name) || reserved.key?(name)) && !server.name.to_s.empty?
            name = "#{server.name}_#{name}"
          end
          add_tool(target_tools, tool, name, reserved)
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
    end

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

      # Binds RubyLLM::Tool classes/instances as host tools callable from
      # inside the sandbox via SB.call:
      #
      #   tools Weather                     # class (instantiated with .new)
      #   tools Weather, Echo               # several at once
      #   tools [Weather, Echo]             # or arrays
      #   tools "forecast" => Weather       # explicit sandbox name
      #   tools forecast: Weather           # same, as kwargs
      #
      # Without arguments it returns the hash of bound tools. The name is
      # derived from the class-name leaf (`MyApp::Tools::Weather` binds as
      # `weather`). Fails fast: every item must be a RubyLLM::Tool (class or
      # instance), names must be unique and non-empty, and if anything goes
      # wrong nothing is bound.
      def tools(*args, **kwargs)
        return @tools ||= {} if args.empty? && kwargs.empty?

        Registry.register_tools(tools, args, kwargs)
      end

      # Connects MCP server(s) and binds all their tools into the sandbox:
      #
      #   docs = RubyLLM.mcp(url: "https://learn.microsoft.com/api/mcp")
      #
      #   class DocsResearch < RubyLLM::CodeMode
      #     mcps docs                    # instance
      #     mcps MicrosoftDocs           # or the class (instantiated with .new)
      #     mcps Linear, user: current_user  # class + declared inputs
      #     mcps Docs, Github            # several servers / arrays at once
      #   end
      #
      # Without arguments it returns the array of connected servers. Server
      # tools keep their names (`microsoft_docs_search`, ...); a tool whose
      # name is already bound is re-bound as "<server>_tool". The servers'
      # instructions (when the server sends them) are snapshotted at
      # definition and listed in the description under "## Server notes".
      # Fails fast: every argument must be a RubyLLM::MCP (class or
      # instance), and if anything goes wrong — a server that cannot be
      # reached, a name that stays colliding after prefixing — nothing is
      # bound.
      def mcps(*servers, **inputs)
        return @mcps ||= [] if servers.empty? && inputs.empty?

        Registry.register_mcps(tools, mcps, servers, inputs)
      end

      def mounts
        @mounts ||= []
      end

      def configuration
        @configuration ||= SecurityBox::Configuration.build(
          timeout_ms: DEFAULT_TIMEOUT_MS,
          fuel_ms: DEFAULT_FUEL_MS,
          mounts: mounts.map(&:payload),
          rpcs: Registry.rpc_handlers(tools)
        )
      end

      # Builds the description the model sees. `extra_tools`/`extra_mcps`
      # carry the per-instance additions (see #add_tools/#add_mcps); with no
      # extras the output is identical to the class-level description.
      def build_description(extra_tools: {}, extra_mcps: [])
        read_only, read_write = mounts.partition { |m| m.mode == :read_only }
        [
          FIXED_DESCRIPTION.rstrip,
          folder_section("## Read-only folders (readable, never writable)", read_only),
          folder_section("## Read-write folders (readable and writable)", read_write),
          Registry.tools_section(tools.merge(extra_tools)),
          Registry.server_notes_section(mcps + extra_mcps)
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

      def folder_section(header, entries)
        return nil if entries.empty?

        lines = entries.map do |entry|
          line = "- `#{entry.guest}`"
          line += " — #{entry.description}" unless entry.description.empty?
          line
        end
        [header, *lines].join("\n")
      end
    end

    parameter :code, description: "Complete Ruby script to execute in the sandbox"

    # Binds more host tools onto this specific instance, on top of the
    # class-level ones. Accepts the same forms as the class-level .tools:
    # classes, ready instances, several at once, arrays, and
    # "name" => tool pairs (hash or kwargs). Instances of the same class are
    # unaffected, and the additions show up in this instance's description,
    # so chats built after the call expose them to the model. Fails fast and
    # rolls everything back; once the first execution happened the sandbox is
    # already built and further additions raise.
    def add_tools(*args, **kwargs)
      ensure_extendable!

      Registry.register_tools(instance_tools, args, kwargs, reserved: self.class.tools)
    end

    # Connects MCP server(s) onto this specific instance, on top of the
    # class-level ones. Same forms and fail-fast semantics as .mcps
    # (instances, classes with their declared inputs, arrays); the servers'
    # tools bind into this instance only. Raises after the first execution.
    def add_mcps(*servers, **inputs)
      ensure_extendable!

      Registry.register_mcps(instance_tools, instance_mcps, servers, inputs, reserved: self.class.tools)
    end

    def description
      self.class.build_description(extra_tools: instance_tools, extra_mcps: instance_mcps)
    end

    def execute(code:)
      format_result(sandbox.eval(code))
    rescue SecurityBox::Error => e
      { status: "sandbox_error", error: { class: e.class.name, message: e.message } }
    end

    private

    def ensure_extendable!
      return unless instance_variable_defined?(:@sandbox)

      raise ArgumentError,
            "cannot add tools or MCP servers after the first execution; " \
            "create a new #{self.class.name} instance instead"
    end

    def instance_tools
      @instance_tools ||= {}
    end

    def instance_mcps
      @instance_mcps ||= []
    end

    # Instances without additions share the class configuration; instances
    # with additions build their own, merging the class rpcs with the
    # instance ones (names cannot collide — the registrations validate that).
    def configuration
      return self.class.configuration if instance_tools.empty? && instance_mcps.empty?

      @configuration ||= SecurityBox::Configuration.build(
        timeout_ms: DEFAULT_TIMEOUT_MS,
        fuel_ms: DEFAULT_FUEL_MS,
        mounts: self.class.mounts.map(&:payload),
        rpcs: self.class.configuration.rpcs.merge(Registry.rpc_handlers(instance_tools))
      )
    end

    def sandbox
      @sandbox ||= SecurityBox::Sandbox.new(configuration)
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
