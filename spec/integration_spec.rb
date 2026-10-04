# frozen_string_literal: true

require_relative "spec_helper"
require "tmpdir"
require "fileutils"

module SandboxTools
  class Adder < RubyLLM::Tool
    description "Adds two integers"

    parameter :a, type: "integer", description: "First addend"
    parameter :b, type: "integer", description: "Second addend"

    def execute(a:, b:)
      { sum: a + b }
    end
  end

  class Failer < RubyLLM::Tool
    description "Always raises"

    def execute
      raise KeyError, "boom"
    end
  end
end

RSpec.describe RubyLLM::CodeMode, "integration (bound tools)" do
  let(:tool_class) do
    Class.new(described_class).tap do |klass|
      klass.tools(SandboxTools::Adder)
      klass.tools("failer" => SandboxTools::Failer)
    end
  end

  let(:tool) { tool_class.new }

  it "returns the bound tool result through SB.call" do
    result = tool.execute(code: 'SB.call("adder", a: 1, b: 2)')

    expect(result).to eq(status: "ok", value: { "sum" => 3 })
  end

  it "reports schema mistakes as an error hash inside value" do
    result = tool.execute(code: 'SB.call("adder", a: 1)')

    expect(result[:status]).to eq("ok")
    expect(result[:value]).to eq("error" => "Invalid tool arguments: missing keyword: b")
  end

  it "surfaces handler failures as rescuable SB::ToolError" do
    result = tool.execute(code: <<~RUBY)
      begin
        SB.call("failer")
        "no raise"
      rescue SB::ToolError => e
        "rescued: \#{e.message}"
      end
    RUBY

    expect(result).to eq(status: "ok", value: "rescued: boom")
  end

  it "fails the evaluation when SB::ToolError is not rescued" do
    result = tool.execute(code: 'SB.call("failer")')

    expect(result[:status]).to eq("error")
    expect(result[:error]["class"]).to eq("SB::ToolError")
    expect(result[:error]["message"]).to eq("boom")
  end

  it "raises SB::UnknownTool for names that were not bound" do
    result = tool.execute(code: <<~RUBY)
      begin
        SB.call("nope")
        "no raise"
      rescue SB::UnknownTool => e
        "unknown: \#{e.message}"
      end
    RUBY

    expect(result).to eq(status: "ok", value: "unknown: unknown rpc: nope")
  end

  it "rejects non-hash arguments with a tool error" do
    result = tool.execute(code: <<~RUBY)
      begin
        SB.call("adder", [1, 2])
        "no raise"
      rescue SB::ToolError => e
        "bad args: \#{e.message}"
      end
    RUBY

    expect(result[:status]).to eq("ok")
    expect(result[:value]).to start_with('bad args: tool "adder" expects a hash')
  end
end

RSpec.describe RubyLLM::CodeMode, "integration (real sandbox)" do
  around do |example|
    Dir.mktmpdir do |read_only_dir|
      Dir.mktmpdir do |read_write_dir|
        @read_only_dir = read_only_dir
        @read_write_dir = read_write_dir
        File.write(File.join(read_only_dir, "input.csv"), "a,b\n1,2\n")
        example.run
      end
    end
  end

  let(:tool_class) do
    Class.new(described_class).tap do |klass|
      klass.mount(source: @read_only_dir, dest: "/data", description: "input csv")
      klass.mount_rw(source: @read_write_dir, dest: "/workspace", description: "generated artifacts")
    end
  end

  let(:tool) { tool_class.new }

  it "evals code and returns the value" do
    expect(tool.execute(code: "40 + 2")).to eq(status: "ok", value: 42)
  end

  it "captures stdout" do
    expect(tool.execute(code: 'puts "hello"')).to eq(
      status: "ok", value: nil, stdout: "hello\n"
    )
  end

  it "returns JSON-serializable values" do
    result = tool.execute(code: '{ "sum" => [1, 2].sum }')

    expect(result).to eq(status: "ok", value: { "sum" => 3 })
  end

  it "returns guest exceptions as errors" do
    result = tool.execute(code: 'raise ArgumentError, "boom"')

    expect(result[:status]).to eq("error")
    expect(result[:error]["class"]).to eq("ArgumentError")
    expect(result[:error]["message"]).to eq("boom")
    expect(result[:error]["backtrace"]).to be_an(Array)
  end

  it "reads mounted read-only folders" do
    result = tool.execute(code: 'File.read("/data/input.csv")')

    expect(result).to eq(status: "ok", value: "a,b\n1,2\n")
  end

  it "refuses to write into read-only mounts" do
    result = tool.execute(code: 'File.write("/data/input.csv", "tampered")')

    expect(result[:status]).to eq("error")
    expect(result[:error]["class"]).to eq("Errno::EPERM")
    expect(File.read(File.join(@read_only_dir, "input.csv"))).to eq("a,b\n1,2\n")
  end

  it "writes through read-write mounts into the host folder" do
    result = tool.execute(code: 'File.write("/workspace/out.txt", "done")')

    expect(result[:status]).to eq("ok")
    expect(File.read(File.join(@read_write_dir, "out.txt"))).to eq("done")
  end

  it "carries state across executions through read-write mounts only" do
    tool.execute(code: 'File.write("/workspace/count.txt", "1")')
    result = tool.execute(code: 'File.read("/workspace/count.txt") + ":" + File.read("/data/input.csv")[0,1]')

    expect(result).to eq(status: "ok", value: "1:a")
  end

  it "does not see the host filesystem outside mounts" do
    result = tool.execute(code: 'File.exist?("/etc/passwd") ? "leaked" : "safe"')

    expect(result).to eq(status: "ok", value: "safe")
  end
end