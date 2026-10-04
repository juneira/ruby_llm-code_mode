# frozen_string_literal: true

module RubyLLM
  class CodeMode
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
    end
  end
end
