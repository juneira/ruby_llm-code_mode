# RubyLLM::CodeMode

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

Define a tool class, declare the host folders the sandbox may see, bind the
host tools and MCP servers the code may call, and give it to your chat:

```ruby
require "ruby_llm"
require "ruby_llm/code_mode"

# A host tool the sandboxed code can call with SB.call("notes", note: "...").
class Notes < RubyLLM::Tool
  description "Records a finding in the analysis log"

  parameter :note, type: "string", description: "The finding to record"

  def execute(note:)
    # host-side write: log file, HTTP call, database query, ...
    { recorded: note }
  end
end

# An MCP server whose tools become callable from inside the sandbox too.
docs = RubyLLM.mcp(url: "https://learn.microsoft.com/api/mcp")

class Analytics < RubyLLM::CodeMode
  mount    source: "data/input", dest: "/data",      description: "CSV files with the raw data (read only)"
  mount_rw source: "workspace",  dest: "/workspace", description: "Write generated reports and artifacts here"

  tools Notes                   # one, several (`tools A, B`) or arrays (`tools [A, B]`)
  mcps   docs                   # one, several (`mcps A, B`) or arrays — classes work too
end

chat = RubyLLM.chat
chat.with_tools(Analytics)
chat.ask "Compute the total sales per month from the CSVs in /data, save the " \
         "report to /workspace/report.md, record the biggest finding in the " \
         "notes log and check the Azure docs for the storage API you used"
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
  parameters, when any are bound with `tools` or `mcps`.

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
tools    SomeRubyLLMTool                                          # host tool
tools    SomeTool, OtherTool                                      # several (or arrays)
tools    "name" => SomeRubyLLMTool                                # explicit name(s)
mcps     SomeMcpServer                                            # MCP server(s) (instance or class)
```

- `source:` — folder on the host machine, relative to the process working
  directory (expanded at class-definition time) or absolute.
- `dest:` — absolute, normalized path inside the sandbox (may not overlap
  the reserved `/work`, `/usr` or `/src` trees, and must be unique).
- `description:` — shown to the model in the tool description.
- `tools` — one or more `RubyLLM::Tool` classes/instances (or arrays of
  them); the name inside the sandbox is derived from the class-name leaf
  (`MyApp::Tools::Weather` → `weather`), or the explicit one from the
  `"name" => tool` pairs. Called without arguments, it returns the bound
  tools.
- `mcps` — one or more `RubyLLM::MCP` instances or classes
  (auto-instantiated, with the server's declared inputs as keywords); all of
  each server's tools are bound under their own names. Called without
  arguments, it returns the connected servers.

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
  tools Weather                    # binds as `weather`
  tools "forecast" => Weather      # or bind it under an explicit name
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

### MCP servers

The `mcps` DSL connects [RubyLLM::MCP](https://rubyllm.com/next/mcp/) servers
and binds all their tools in one call, letting the sandboxed code reach the
server through the host RPC channel:

```ruby
docs = RubyLLM.mcp(url: "https://learn.microsoft.com/api/mcp")

class DocsResearch < RubyLLM::CodeMode
  mcps docs                       # instance
  # mcps MicrosoftDocs            # or the class (instantiated with .new)
  # mcps Linear, user: current_user  # class + the server's declared inputs
end
```

Each server tool keeps its server name and its JSON schema is rendered into
the tool description, so inside the sandbox the model writes:

```ruby
result = SB.call("microsoft_docs_search", query: "Azure Blob Storage")
result[:text]       # => the tool's text output
result[:structured] # => parsed structured content, or nil
result[:error]      # => true when the tool reported a failure
```

- A tool whose name is already bound is re-bound as `<server>_tool`
  (`search` on server `github` → `github_search`); a name that still collides
  after prefixing raises at definition time.
- Servers that send `instructions` have them listed in the description under
  a "## Server notes" section.
- Everything fails fast: an argument that is not a `RubyLLM::MCP`, a server
  that cannot be reached, or a stuck name collision roll the whole call back
  and raise at definition time.
- The class form binds the tools of one instance built at definition time —
  for servers that act per-user, pass a ready instance instead
  (`mcps Linear.new(user: current_user)`) where the user is available.

The sandbox itself never sees the network — every `SB.call` performs the MCP
request on the host. A runnable example lives in `sample/ruby_llm_mcp/`.

### Per-instance tools and servers

Class-level `tools`/`mcps` bind once for every instance of the class. When the
same tool class needs a different toolset per chat — per-user credentials, a
server list composed at runtime — bind additions on the instance instead:

```ruby
tool = Analytics.new
tool.add_tools(UserSearch.new(user: current_user))   # ready instance (classes work too)
tool.add_mcps(user_linear)                           # server instance, class or array

chat = RubyLLM.chat
chat.with_tools(tool)   # the description already includes the additions
chat.ask "Search the docs and log the findings"
tool.execute(code: 'SB.call("user_search", q: "...")')
```

- `add_tools` accepts the same forms as `tools`: classes, ready instances,
  several at once, arrays and `"name" => tool` pairs. Names may not collide
  with the class-level bindings or each other, and the 64-tool limit counts
  both levels together.
- `add_mcps` accepts the same forms as `mcps`; the servers' tools bind into
  this instance only — other instances and the class itself are unaffected.
- Both are all-or-nothing: on any failure nothing is bound.
- The instance description includes the additions, so register the tool with
  the chat after calling them.
- The sandbox is configured on the first execution: after that,
  `add_tools`/`add_mcps` raise — create a new instance instead. Instances
  without additions share the class configuration.

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
