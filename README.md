# ruby_llm-code_mode

A [RubyLLM](https://rubyllm.com) tool that runs model-generated Ruby code inside a
secure sandbox, powered by [SecurityBox](https://rubygems.org/gems/security_box).

The model writes Ruby; the code runs as a fresh Ruby 4.0 process inside a
WebAssembly sandbox (ruby.wasm + wasmtime) with no network, no threads, no
subprocesses and no access to the host filesystem — except the folders you
explicitly mount, which are read-only by default.

## Installation

```bash
gem install ruby_llm-code_mode
```

Or add to your Gemfile:

```ruby
gem "ruby_llm-code_mode"
```

## Usage

Define a tool class, declare the host folders the sandbox may see, and give it to
your chat:

```ruby
require "ruby_llm"
require "ruby_llm/code_mode"

class Analytics < RubyLLM::CodeMode
  mount    source: "data/input", dest: "/data",      description: "CSV files with the raw data (read only)"
  mount_rw source: "workspace",  dest: "/workspace", description: "Write generated reports and artifacts here"
end

chat = RubyLLM.chat
chat.with_tools(Analytics)
chat.ask "Compute the total sales per month from the CSVs in /data and save the report to /workspace/report.md"
```

### What the model sees

The tool is presented to the model as `analytics` (derived from the class name) with
a fixed description built from the declared mounts:

- a **How to use** section: the code runs as a fresh Ruby 4.0 process, isolated
  from the host, with a private `/work` scratch directory wiped between
  executions and no state carried over between runs;
- a **Read-only folders** section listing each `mount` as `` `/guest/path` — description``;
- a **Read-write folders** section listing each `mount_rw`;
- a **Host tools** section listing every bound `RubyLLM::Tool` with its
  parameters, when any are bound with `tool`.

The single parameter is `code` — a complete, self-contained Ruby script.

### What the tool returns

A JSON object sent back to the model:

| status | payload |
|---|---|
| `ok` | `{status:, value:, stdout?}` — value of the last expression, captured `puts` output |
| `error` | `{status:, error: {class, message, backtrace}, stdout?}` — guest exception details |
| `timeout` / `fuel_exhausted` / `memory_limit` | `{status:, error:}` — resource limit hit |
| `sandbox_error` | `{status:, error:, stderr?}` — the sandbox itself failed |

### DSL

```ruby
mount    source: host_path, dest: guest_path, description: "..."  # read-only
mount_rw source: host_path, dest: guest_path, description: "..." # read-write
tool     SomeRubyLLMTool                                          # host tool
tool     "name" => SomeRubyLLMTool                                # explicit name
```

- `source:` — folder on the host machine, relative to the process working
  directory (expanded at class-definition time) or absolute.
- `dest:` — absolute, normalized path inside the sandbox (may not overlap
  the reserved `/work`, `/usr` or `/src` trees, and must be unique).
- `description:` — shown to the model in the tool description.
- `tool` — a `RubyLLM::Tool` class or instance; the name inside the sandbox
  is derived from the class-name leaf (`MyApp::Tools::Weather` → `weather`),
  or the explicit one from the one-pair form.

Invalid declarations raise at class-definition time, so a misconfigured tool
never reaches a live chat. Subclasses inherit their parent's mounts and tools.

### Host tools

Bind existing `RubyLLM::Tool`s so the sandboxed code can call them through
SecurityBox's host RPC channel:

```ruby
class Weather < RubyLLM::Tool
  description "Current weather for a city"
  parameter :city, type: "string", description: "City name"

  def execute(city:)
    # host-side HTTP call, database query, ...
  end
end

class Assistant < RubyLLM::CodeMode
  mount source: "data", dest: "/data", description: "Project data"
  tool  Weather                 # binds as `weather`
  tool  "forecast" => Weather   # or bind it under an explicit name
end
```

The description tells the model what is available, and inside the sandbox it
writes Ruby like:

```ruby
report = SB.call("weather", city: "Porto Alegre")
```

- Bound classes are instantiated once at definition time; every call shares
  that instance, so state persists across calls (like the sandbox itself).
- Arguments must be JSON-serializable; they arrive as the tool's keyword
  arguments (top-level string keys become symbols, nested data keeps string
  keys). Bad arguments come back as an `error` hash — RubyLLM's
  recoverable-failure convention.
- The return value is JSON round-tripped: hashes, arrays and scalars pass
  through; non-serializable objects surface as their `inspect` string.
- A tool that raises surfaces as `SB::ToolError` (class name and message
  only — no backtrace), which the sandboxed code can rescue. Unbound names
  raise `SB::UnknownTool`.
- Limits per execution: 1000 tool calls and 1 MiB per result. At most 64
  tools can be bound to one class.
- A `RubyLLM::CodeMode` cannot be bound inside another `CodeMode`.

### Sandbox limits

Defaults: `timeout_ms: 30_000` (wall clock), `fuel_ms: 10_000` (CPU budget).
Call `MyTool.warmup` at boot to pay the WebAssembly compilation cost up front —
every subsequent evaluation then takes a few hundred milliseconds.

## Security notes

- Mounted folders are fully readable by the executed code — only mount folders
  whose content you are willing to expose.
- Read-only mounts are enforced by wasmtime: writes fail inside the sandbox and
  never touch the host folder.
- Read-write mounts are part of the guest's blast radius: the model can create,
  modify and delete files in them.
- Guest code is sandboxed by [SecurityBox](https://rubygems.org/gems/security_box):
  no network, no threads, no processes, no host filesystem beyond the mounts,
  deterministic CPU/memory/time limits, and forged results are rejected.
- Bound host tools execute on the host, behind the sandbox's call boundary:
  their arguments come from model-generated code, so treat them as untrusted
  input, and only bind tools whose effects you are willing to grant the model.

## Development

```bash
bundle install
bundle exec rspec
```

### Releasing

The version lives in the `VERSION` constant of `lib/ruby_llm/code_mode.rb`
(the gemspec parses it from the source).

```bash
rake version:bump[minor]          # bump: major, minor or patch (default: patch)
git commit -am "Bump version to X.Y.Z"
rake release                      # specs + git tag vX.Y.Z + push to GitHub + push gem to RubyGems
```

`rake release` refuses a dirty working tree or an existing tag and uses the
RubyGems credentials from `~/.gem/credentials`.