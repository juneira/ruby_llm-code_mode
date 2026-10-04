# frozen_string_literal: true

module RubyLLM
  class CodeMode
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

        # One RPC handler per bound tool, ready for
        # SecurityBox::Configuration.build(rpcs:). Each handler validates
        # that the guest passed a hash of arguments, forwards the call to
        # the tool instance (string keys symbolized, schema mistakes coming
        # back as RubyLLM's recoverable error hash) and normalizes MCP
        # Result objects into plain data for the guest.
        def rpc_handlers(tools)
          tools.transform_values { |entry| ->(args) { call_bound_tool(entry, args) } }
        end

        # The "## Host tools (call with SB.call)" description section: the
        # shared intro plus one line per tool with its description and
        # parameter docs. Returns nil when no tools are bound, so the
        # section is omitted from the description entirely.
        def tools_section(tools)
          return nil if tools.empty?

          [
            "## Host tools (call with SB.call)",
            HOST_TOOLS_INTRO.rstrip,
            *tools.values.flat_map { |entry| tool_lines(entry) }
          ].join("\n")
        end

        # The "## Server notes" description section: one line per connected
        # MCP server that sent instructions. Returns nil when no server
        # did, so the section is omitted from the description entirely.
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
  end
end
