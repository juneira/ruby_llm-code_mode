# frozen_string_literal: true

module RubyLLM
  class CodeMode
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

    class << self
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

      private

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
  end
end
