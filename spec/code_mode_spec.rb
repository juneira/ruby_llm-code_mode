# frozen_string_literal: true

require_relative "spec_helper"

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