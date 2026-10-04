# frozen_string_literal: true

require_relative "spec_helper"

module SpecTools
  class Adder < RubyLLM::Tool
    description "Adds two integers"

    parameter :a, type: "integer", description: "First addend"
    parameter :b, type: "integer", description: "Second addend"

    def execute(a:, b:)
      { sum: a + b }
    end
  end

  class Echo < RubyLLM::Tool
    description "Echoes its message"

    parameter :message, type: "string", required: false, description: "Text to echo"

    def execute(message: "empty")
      { echoed: message }
    end
  end

  class Bare < RubyLLM::Tool
    def execute(**)
      nil
    end
  end

  # Stands in for a RubyLLM::MCP::Tool: the name comes from the server,
  # not from the class.
  class Remote < RubyLLM::Tool
    attr_reader :name, :server_name, :description, :parameters_schema

    def initialize(name:, description: "Fake remote tool", parameters_schema: {})
      super()
      @name = name
      @server_name = name
      @description = description
      @parameters_schema = parameters_schema
    end

    def execute(**)
      {}
    end
  end
end

RSpec.describe RubyLLM::CodeMode do
  it "is a RubyLLM::Tool" do
    expect(described_class.superclass).to eq(RubyLLM::Tool)
  end

  it "is named code_mode" do
    expect(described_class.tool_name).to eq("code_mode")
  end

  describe ".mount / .mount_rw" do
    it "registers a read-only mount with the expanded host path" do
      klass = Class.new(described_class)
      klass.mount(source: "data/input", dest: "/data", description: "input files")
      mount = klass.mounts.first
      expect(mount.mode).to eq(:read_only)
      expect(mount.host).to eq(File.expand_path("data/input"))
      expect(mount.guest).to eq("/data")
      expect(mount.description).to eq("input files")
    end

    it "registers a writable mount with mount_rw" do
      klass = Class.new(described_class)
      klass.mount_rw(source: "state", dest: "/state", description: "writable state")
      expect(klass.mounts.first.mode).to eq(:read_write)
    end

    it "expands an absolute host path to itself" do
      klass = Class.new(described_class)
      klass.mount(source: "/etc", dest: "/etc-data", description: "etc")
      expect(klass.mounts.first.host).to eq("/etc")
    end

    it "inherits parent mounts into subclasses without sharing the array" do
      parent = Class.new(described_class)
      parent.mount(source: "data", dest: "/data", description: "shared data")
      child = Class.new(parent)
      child.mount_rw(source: "state", dest: "/state", description: "writable")
      expect(child.mounts.map(&:mode)).to eq(%i[read_only read_write])
      expect(parent.mounts.size).to eq(1)
    end

    it "rejects a relative guest path at definition time and rolls back" do
      klass = Class.new(described_class)

      expect { klass.mount(source: "data", dest: "data", description: "d") }
        .to raise_error(ArgumentError, /guest path must be absolute/)
      expect(klass.mounts).to be_empty
    end

    it "rejects duplicate guest paths at definition time" do
      klass = Class.new(described_class)
      klass.mount(source: "a", dest: "/data", description: "d")
      expect { klass.mount_rw(source: "b", dest: "/data", description: "w") }
        .to raise_error(ArgumentError, /duplicate guest mount path/)
      expect(klass.mounts.size).to eq(1)
    end

    it "rejects reserved guest paths at definition time" do
      klass = Class.new(described_class)

      expect { klass.mount(source: "a", dest: "/work", description: "d") }
        .to raise_error(ArgumentError, /reserved/)
      expect { klass.mount(source: "a", dest: "/usr", description: "d") }
        .to raise_error(ArgumentError, /reserved/)
    end

    it "rejects more than 16 mounts at definition time" do
      klass = Class.new(described_class)
      16.times { |i| klass.mount(source: "a#{i}", dest: "/d#{i}", description: "d") }

      expect { klass.mount(source: "a17", dest: "/d17", description: "d") }
        .to raise_error(ArgumentError, /too many mounts/)
    end
  end

  describe ".tools" do
    it "registers a tool class and derives the name from tool_name" do
      klass = Class.new(described_class)
      klass.tools(SpecTools::Adder)

      entry = klass.tools["adder"]
      expect(entry).to be_a(described_class::ToolEntry)
      expect(entry.name).to eq("adder")
      expect(entry.tool).to be_an_instance_of(SpecTools::Adder)
    end

    it "registers a tool instance as-is" do
      klass = Class.new(described_class)
      instance = SpecTools::Echo.new
      klass.tools(instance)

      expect(klass.tools["echo"].tool).to equal(instance)
    end

    it "accepts an explicit name via a one-pair hash" do
      klass = Class.new(described_class)
      klass.tools("sum" => SpecTools::Adder)

      expect(klass.tools["sum"].tool).to be_an_instance_of(SpecTools::Adder)
    end

    it "accepts an explicit name via kwargs" do
      klass = Class.new(described_class)
      klass.tools(sum: SpecTools::Adder)

      expect(klass.tools.key?("sum")).to be(true)
    end

    it "accepts several tools as varargs or arrays" do
      klass = Class.new(described_class)
      klass.tools(SpecTools::Adder, [SpecTools::Echo])

      expect(klass.tools.keys).to eq(%w[adder echo])
    end

    it "accepts several explicit names via a hash or kwargs" do
      klass = Class.new(described_class)
      klass.tools("sum" => SpecTools::Adder, greet: SpecTools::Echo)

      expect(klass.tools.keys).to eq(%w[sum greet])
    end

    it "returns the bound tools when called without arguments" do
      klass = Class.new(described_class)
      expect(klass.tools).to eq({})

      klass.tools(SpecTools::Adder)
      expect(klass.tools.keys).to eq(%w[adder])
    end

    it "rejects anything that is not a RubyLLM::Tool class or instance" do
      klass = Class.new(described_class)

      expect { klass.tools(Object) }
        .to raise_error(ArgumentError, /expected a RubyLLM::Tool/)
      expect { klass.tools("x" => "not a tool") }
        .to raise_error(ArgumentError, /expected a RubyLLM::Tool/)
      expect(klass.tools).to be_empty
    end

    it "rolls back everything when one of several tools is invalid" do
      klass = Class.new(described_class)

      expect { klass.tools(SpecTools::Adder, Object) }
        .to raise_error(ArgumentError, /expected a RubyLLM::Tool/)
      expect(klass.tools).to be_empty
    end

    it "rejects an empty derived name (anonymous tool class)" do
      klass = Class.new(described_class)

      expect { klass.tools(Class.new(RubyLLM::Tool)) }
        .to raise_error(ArgumentError, /non-empty/)
      expect(klass.tools).to be_empty
    end

    it "rejects duplicate names at definition time" do
      klass = Class.new(described_class)
      klass.tools(SpecTools::Adder)

      expect { klass.tools("adder" => SpecTools::Echo) }
        .to raise_error(ArgumentError, /already bound/)
      expect(klass.tools.size).to eq(1)
    end

    it "rejects more than 64 tools at definition time" do
      klass = Class.new(described_class)
      64.times { |i| klass.tools("t#{i}" => SpecTools::Adder) }

      expect { klass.tools("t65" => SpecTools::Adder) }
        .to raise_error(ArgumentError, /limit is 64/)
    end

    it "rejects binding a CodeMode inside another CodeMode" do
      klass = Class.new(described_class)

      expect { klass.tools(Class.new(described_class)) }
        .to raise_error(ArgumentError, /CodeMode/)
      expect(klass.tools).to be_empty
    end

    it "inherits parent tools into subclasses without sharing the hash" do
      parent = Class.new(described_class)
      parent.tools(SpecTools::Adder)
      child = Class.new(parent)
      child.tools(SpecTools::Echo)

      expect(child.tools.keys).to eq(%w[adder echo])
      expect(parent.tools.size).to eq(1)
    end
  end

  describe ".mcps" do
    # Stands in for RubyLLM::MCP when the released gem (2.0) has none.
    let(:mcp_base) do
      Class.new do
        attr_reader :name, :tools, :instructions

        def initialize(name: "fake_server", tools: [], instructions: "")
          @name = name
          @tools = tools
          @instructions = instructions
        end
      end
    end

    before { stub_const("RubyLLM::MCP", mcp_base) }

    def fake_server(name: "docs", tools:, instructions: "")
      Class.new(mcp_base).new(name: name, tools: tools, instructions: instructions)
    end

    it "binds a server's tools under their own names" do
      klass = Class.new(described_class)
      klass.mcps(fake_server(tools: [
        SpecTools::Remote.new(name: "microsoft_docs_search"),
        SpecTools::Remote.new(name: "microsoft_docs_fetch")
      ]))

      expect(klass.tools.keys).to eq(%w[microsoft_docs_search microsoft_docs_fetch])
      expect(klass.mcps.map(&:name)).to eq(%w[docs])
    end

    it "accepts several servers, varargs and arrays" do
      klass = Class.new(described_class)
      klass.mcps(
        fake_server(name: "docs", tools: [SpecTools::Remote.new(name: "docs_search")]),
        [fake_server(name: "github", tools: [SpecTools::Remote.new(name: "list_issues")])]
      )

      expect(klass.tools.keys).to eq(%w[docs_search list_issues])
      expect(klass.mcps.map(&:name)).to eq(%w[docs github])
    end

    it "instantiates a class argument" do
      klass = Class.new(described_class)
      server_class = Class.new(mcp_base)
      klass.mcps(server_class)

      expect(klass.mcps.first.mcp).to be_an_instance_of(server_class)
      expect(klass.tools).to be_empty
    end

    it "instantiates a class argument with the declared inputs" do
      klass = Class.new(described_class)
      server_class = Class.new(mcp_base)
      instance = fake_server(tools: [SpecTools::Remote.new(name: "list_issues")])
      allow(server_class).to receive(:new).with(user: "juneira").and_return(instance)

      klass.mcps(server_class, user: "juneira")

      expect(klass.tools.keys).to eq(%w[list_issues])
    end

    it "rejects inputs when passing ready instances" do
      klass = Class.new(described_class)

      expect { klass.mcps(fake_server(tools: []), user: "juneira") }
        .to raise_error(ArgumentError, /inputs only apply/)
      expect(klass.mcps).to be_empty
    end

    it "rejects anything that is not a RubyLLM::MCP" do
      klass = Class.new(described_class)

      expect { klass.mcps(Object.new) }
        .to raise_error(ArgumentError, /expected a RubyLLM::MCP/)
      expect { klass.mcps(Object) }
        .to raise_error(ArgumentError, /expected a RubyLLM::MCP/)
      expect { klass.mcps(fake_server(tools: []), Object) }
        .to raise_error(ArgumentError, /expected a RubyLLM::MCP/)
      expect(klass.tools).to be_empty
      expect(klass.mcps).to be_empty
    end

    it "returns the connected servers when called without arguments" do
      klass = Class.new(described_class)
      expect(klass.mcps).to eq([])

      klass.mcps(fake_server(tools: []))
      expect(klass.mcps.map(&:name)).to eq(%w[docs])
    end

    it "auto-prefixes a colliding tool name with the server name" do
      klass = Class.new(described_class)
      klass.tools(SpecTools::Adder) # binds as "adder"

      klass.mcps(fake_server(name: "github", tools: [
        SpecTools::Remote.new(name: "adder"),
        SpecTools::Remote.new(name: "list_issues")
      ]))

      expect(klass.tools.keys).to eq(%w[adder github_adder list_issues])
    end

    it "fails fast when even the prefixed name collides" do
      klass = Class.new(described_class)

      expect do
        klass.mcps(
          fake_server(name: "gitlab", tools: [SpecTools::Remote.new(name: "search")]),
          fake_server(name: "gitlab", tools: [SpecTools::Remote.new(name: "search")]),
          fake_server(name: "gitlab", tools: [SpecTools::Remote.new(name: "search")])
        )
      end.to raise_error(ArgumentError, /already bound/)
      expect(klass.tools).to be_empty
      expect(klass.mcps).to be_empty
    end

    it "rolls back everything when a server cannot be reached" do
      klass = Class.new(described_class)
      broken = fake_server(tools: [])
      def broken.tools
        raise "connection failed"
      end

      expect { klass.mcps(fake_server(tools: [SpecTools::Remote.new(name: "docs_search")]), broken) }
        .to raise_error(RuntimeError, /connection failed/)
      expect(klass.tools).to be_empty
      expect(klass.mcps).to be_empty
    end

    it "inherits parent mcps into subclasses" do
      parent = Class.new(described_class)
      parent.mcps(fake_server(tools: [SpecTools::Remote.new(name: "docs_search")]))
      child = Class.new(parent)

      expect(child.mcps.map(&:name)).to eq(%w[docs])
      expect(child.tools.keys).to eq(%w[docs_search])
      expect(parent.mcps.size).to eq(1)
    end

    it "lists the tools' descriptions and schemas in the description" do
      klass = Class.new(described_class)
      klass.mcps(fake_server(tools: [SpecTools::Remote.new(
        name: "docs_search",
        description: "Search Microsoft documentation",
        parameters_schema: {
          "properties" => { "query" => { "type" => "string", "description" => "What to look for" } },
          "required" => ["query"]
        }
      )]))
      description = klass.description

      expect(description).to include("- `docs_search` — Search Microsoft documentation")
      expect(description).to include("  - `query` (string, required) — What to look for")
    end

    it "lists the servers' instructions under a Server notes section" do
      klass = Class.new(described_class)
      klass.mcps(
        fake_server(name: "docs", tools: [SpecTools::Remote.new(name: "docs_search")],
                    instructions: "Search official Microsoft docs."),
        fake_server(name: "quiet", tools: [])
      )
      description = klass.description

      expect(description).to include("## Server notes")
      expect(description).to include("- **docs** — Search official Microsoft docs.")
      expect(description).not_to include("**quiet**")
      expect(description.index("Host tools")).to be < description.index("Server notes")
    end

    it "omits the Server notes section when no server sends instructions" do
      klass = Class.new(described_class)
      klass.mcps(fake_server(tools: []))
      expect(klass.description).not_to include("Server notes")
    end
  end

  describe ".description" do
    it "refuses to be set by hand" do
      expect { described_class.description("custom") }
        .to raise_error(ArgumentError, /fixed/)
    end

    it "returns only the fixed description when there are no mounts" do
      klass = Class.new(described_class)
      description = klass.description

      expect(description).to include("secure sandbox")
      expect(description).to include("`/work`")
      expect(description).not_to include("Read-only folders")
      expect(description).not_to include("Read-write folders")
    end

    it "lists mounts under their own sections" do
      klass = Class.new(described_class)
      klass.mount(source: "data/input", dest: "/data", description: "input CSVs")
      klass.mount_rw(source: "workspace", dest: "/workspace", description: "generated artifacts")
      description = klass.description
      expect(description).to include("## Read-only folders")
      expect(description).to include("- `/data` — input CSVs")
      expect(description).to include("## Read-write folders")
      expect(description).to include("- `/workspace` — generated artifacts")
      expect(description.index("Read-only folders")).to be < description.index("Read-write folders")
    end

    it "omits the host-tools section when no tools are bound" do
      klass = Class.new(described_class)
      expect(klass.description).not_to include("Host tools")
    end

    it "lists bound tools with their parameters after the folder sections" do
      klass = Class.new(described_class)
      klass.mount(source: "data", dest: "/data", description: "d")
      klass.tools(SpecTools::Adder)
      klass.tools(SpecTools::Echo)
      description = klass.description

      expect(description).to include("## Host tools (call with SB.call)")
      expect(description).to include("SB.call('name', key: value)")
      expect(description).to include("- `adder` — Adds two integers")
      expect(description).to include("  - `a` (integer, required) — First addend")
      expect(description).to include("  - `b` (integer, required) — Second addend")
      expect(description).to include("  - `message` (string, optional) — Text to echo")
      expect(description.index("Read-only folders")).to be < description.index("Host tools")
    end

    it "lists a tool without description or parameters as a bare line" do
      klass = Class.new(described_class)
      klass.tools(SpecTools::Bare)
      expect(klass.description).to end_with("- `bare`")
    end

    it "omits the separator when a mount has no description" do
      klass = Class.new(described_class)
      klass.mount(source: "data", dest: "/data", description: nil)
      expect(klass.description).to end_with("- `/data`")
    end

    it "is what tool instances report" do
      expect(described_class.new.description).to eq(described_class.build_description)
    end
  end

  describe ".configuration" do
    it "builds a SecurityBox configuration with the declared mounts and the defaults" do
      klass = Class.new(described_class)
      klass.mount(source: "data", dest: "/data", description: "d")
      config = klass.configuration

      expect(config).to be_a(SecurityBox::Configuration)
      expect(config.timeout_ms).to eq(30_000)
      expect(config.fuel_ms).to eq(10_000)
      expect(config.mounts).to eq(
        [{ host: File.expand_path("data"), guest: "/data", mode: :read_only }]
      )
    end

    it "is memoized per class" do
      klass = Class.new(described_class)
      expect(klass.configuration).to equal(klass.configuration)

      child = Class.new(klass)
      expect(child.configuration).not_to equal(klass.configuration)
    end

    it "passes the bound tools as host rpc handlers" do
      klass = Class.new(described_class)
      klass.tools(SpecTools::Adder)
      klass.tools(SpecTools::Echo)
      config = klass.configuration

      expect(config.rpcs.keys).to eq(%w[adder echo])
      expect(config.rpcs["adder"]).to respond_to(:call)
    end

    it "gives handlers string-keyed args that reach execute with symbol keys" do
      klass = Class.new(described_class)
      klass.tools(SpecTools::Adder)

      result = klass.configuration.rpcs["adder"].call({ "a" => 1, "b" => 2 })
      expect(result).to eq(sum: 3)
    end

    it "reports schema mistakes through RubyLLM's error convention" do
      klass = Class.new(described_class)
      klass.tools(SpecTools::Adder)

      result = klass.configuration.rpcs["adder"].call({ "a" => 1 })
      expect(result).to eq(error: "Invalid tool arguments: missing keyword: b")
    end

    it "rejects non-hash arguments with a clear message" do
      klass = Class.new(described_class)
      klass.tools(SpecTools::Adder)

      expect { klass.configuration.rpcs["adder"].call([1, 2]) }
        .to raise_error(ArgumentError, /expects a hash of arguments, got Array/)
    end

    it "leaves rpcs empty when no tools are bound" do
      klass = Class.new(described_class)
      expect(klass.configuration.rpcs).to eq({})
    end

    it "normalizes MCP tool results into plain data for the guest" do
      result_class = Class.new do
        def text = "Azure Blob docs"
        def structured = { "results" => [] }
        def error? = false
      end
      stub_const("RubyLLM::MCP::Result", result_class)

      remote = SpecTools::Remote.new(name: "docs_search")
      allow(remote).to receive(:call).and_return(result_class.new)

      klass = Class.new(described_class)
      klass.tools(remote)

      expect(klass.configuration.rpcs["docs_search"].call({}))
        .to eq(text: "Azure Blob docs", structured: { "results" => [] }, error: false)
    end
  end

  describe "#execute" do
    let(:tool) { described_class.new }
    let(:sandbox) { instance_double(SecurityBox::Sandbox) }

    before do
      allow(SecurityBox::Sandbox).to receive(:new).and_return(sandbox)
    end

    def stub_eval(result)
      allow(sandbox).to receive(:eval).and_return(result)
    end

    def result(status, **attrs)
      SecurityBox::Result.new(status: status, **attrs)
    end

    it "formats a successful result" do
      stub_eval(result(:ok, value: 42, stdout: "hello\n"))

      expect(tool.execute(code: "40 + 2")).to eq(
        status: "ok", value: 42, stdout: "hello\n"
      )
    end

    it "omits stdout when empty" do
      stub_eval(result(:ok, value: nil, stdout: ""))

      expect(tool.execute(code: "nil")).to eq(status: "ok", value: nil)
    end

    it "formats a guest exception" do
      stub_eval(result(
        :error,
        error: { "class" => "ArgumentError", "message" => "boom", "backtrace" => ["sandbox:1"] },
        stdout: "partial\n"
      ))

      expect(tool.execute(code: "boom")).to eq(
        status: "error",
        error: { "class" => "ArgumentError", "message" => "boom", "backtrace" => ["sandbox:1"] },
        stdout: "partial\n"
      )
    end

    it "formats resource-limit results" do
      stub_eval(result(:timeout))
      expect(tool.execute(code: "loop {}"))
        .to eq(status: "timeout", error: "execution timed out before finishing")

      stub_eval(result(:fuel_exhausted))
      expect(tool.execute(code: "loop {}"))
        .to eq(status: "fuel_exhausted", error: "execution exceeded its CPU budget before finishing")

      stub_eval(result(:memory_limit))
      expect(tool.execute(code: "[] * 1_000_000"))
        .to eq(status: "memory_limit", error: "execution exceeded the sandbox memory limit")

      stub_eval(result(:sandbox_error, stderr: "security_box: boom\n"))
      expect(tool.execute(code: "1")).to eq(
        status: "sandbox_error", error: "the sandbox failed to run the code", stderr: "security_box: boom\n"
      )
    end

    it "returns a recoverable error when the sandbox itself fails" do
      allow(SecurityBox::Sandbox).to receive(:new).and_raise(SecurityBox::ImageMissing, "image not found")

      expect(tool.execute(code: "1")).to eq(
        status: "sandbox_error",
        error: { class: "SecurityBox::ImageMissing", message: "image not found" }
      )
    end
  end

  describe "parameters" do
    it "declares the code parameter as required string" do
      schema = described_class.new.parameters_schema

      expect(schema["properties"]).to include("code" => hash_including("type" => "string"))
      expect(schema["required"]).to eq(["code"])
    end
  end
end