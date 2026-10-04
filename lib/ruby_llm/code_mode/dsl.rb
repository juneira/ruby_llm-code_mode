# frozen_string_literal: true

module RubyLLM
  class CodeMode
    class << self
      # The tool name presented to the model: the underscored class-name leaf
      # (`MyApp::Tools::Weather` → `weather`, `SalesNotes` → `sales_notes`),
      # without the `_tool` suffix. The base RubyLLM::Tool.tool_name would
      # leak the namespace (`ruby_llm--code_mode`), so CodeMode derives the
      # name from the leaf only.
      def tool_name
        leaf = name.to_s.split('::').last
        return '' unless leaf

        RubyLLM::Support::Utils.underscore(leaf).delete_suffix('_tool')
      end

      # Mounts a host folder into the sandbox as read-only. `source:` is
      # expanded against the boot working directory (absolute paths pass
      # through); `dest:` must be absolute, unique and outside the reserved
      # trees (`/work`, `/usr`, `/src`). Invalid declarations raise
      # ArgumentError at class-definition time, so a misconfigured tool
      # never reaches a live chat.
      def mount(source:, dest:, description: nil)
        add_mount(source, dest, :read_only, description)
      end

      # Same as .mount, but the sandboxed code can create, modify and delete
      # files inside the folder (enforced by wasmtime; the contents persist
      # between executions of the same tool instance).
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

      # The mounts declared so far, as Mount structs (read-only and
      # read-write together, in declaration order). Subclasses start with a
      # copy of the parent's list, so adding to a child never touches the
      # parent.
      def mounts
        @mounts ||= []
      end

      # Builds and memoizes the SecurityBox::Configuration for this class:
      # the default limits (timeout_ms: 30_000, fuel_ms: 10_000), the
      # declared mounts and one RPC handler per bound tool. Memoized per
      # class; subclasses build their own. Tool instances without
      # per-instance additions share it (see #add_tools).
      def configuration
        @configuration ||= SecurityBox::Configuration.build(
          timeout_ms: DEFAULT_TIMEOUT_MS,
          fuel_ms: DEFAULT_FUEL_MS,
          mounts: mounts.map(&:payload),
          rpcs: Registry.rpc_handlers(tools)
        )
      end

      # Pays the WebAssembly compilation cost up front (about 15 seconds on
      # the first run, cached afterwards in ~/.cache/security_box/modules),
      # so the first real execution takes a few hundred milliseconds
      # instead. Call it once at boot: Analytics.warmup.
      def warmup
        SecurityBox.warmup(timeout_ms: DEFAULT_TIMEOUT_MS, fuel_ms: DEFAULT_FUEL_MS)
      end

      # Ruby hook: subclasses start with a copy of the parent's mounts,
      # tools and MCP servers (entries and instances shared), and their own
      # configuration memo so limits/rpcs are rebuilt per class.
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
    end
  end
end
