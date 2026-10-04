# AGENTS.md

Instructions for coding agents working on this repository.

## What this project is

`ruby_llm-code_mode` is a gem exposing the `RubyLLM::CodeMode` tool for
[RubyLLM](https://rubyllm.com): execution of **model-generated** Ruby code
inside the secure [SecurityBox](https://rubygems.org/gems/security_box)
sandbox (ruby.wasm + wasmtime), with host-folder mounts declared via DSL and
host `RubyLLM::Tool`s bound for the guest to call via `SB.call`.

- Gem: `ruby_llm-code_mode` v0.1.0, Ruby >= 4.0, MIT
- Namespace: class `RubyLLM::CodeMode` (subclass of `RubyLLM::Tool`)
- Tool name: derived from the last class-name segment (`CsvReader` →
  `csv_reader`) — `tool_name` is overridden to ignore the `RubyLLM::` prefix

## Structure

```
lib/ruby_llm/code_mode.rb      EVERYTHING of the gem (class + DSL + Mount/ToolEntry Structs + version)
spec/code_mode_spec.rb         unit specs (DSL, description, configuration, rpc handlers, format_result)
spec/integration_spec.rb       integration specs (real sandbox, real wasm)
spec/spec_helper.rb
sample/csv_reader/             functional example (OpenRouter, deepseek-v4.1-flash)
sample/ruby_llm_mcp/           functional example binding RubyLLM::MCP server tools
                               (learn.microsoft.com/api/mcp; needs a local ruby_llm clone)
ruby_llm-code_mode.gemspec     deps: ruby_llm >= 2.0, security_box >= 0.6
```

**Important:** `version.rb` and `mount.rb` were deliberately consolidated into
`lib/ruby_llm/code_mode.rb`. Separate files that declare
`module RubyLLM; class CodeMode` without a superclass break the load
(`superclass mismatch` when `code_mode.rb` redefines `class CodeMode < Tool`).
If you create sub-files, they must only reopen the class (no `superclass`) or
be required **after** the class definition.

## Commands

```bash
bundle install          # setup
bundle exec rspec       # full suite (unit + integration)
ruby -c lib/ruby_llm/code_mode.rb   # quick syntax check
```

### Release flow

Single source of truth for the version: the `VERSION` constant inside
`lib/ruby_llm/code_mode.rb` (the gemspec parses it from the source).

```bash
bundle exec rake 'version:bump[minor]'   # bump version: major, minor or patch (default: patch)
git commit -am "Bump version to X.Y.Z"
bundle exec rake release                 # runs specs, then creates tag vX.Y.Z,
                                         # pushes branch + tag to GitHub (origin)
                                         # and pushes the gem to RubyGems
```

`rake release` refuses to run when the working tree is dirty or the tag
already exists. It needs RubyGems credentials (~/.gem/credentials) for the
`gem push` step. In zsh, quote the bump argument (`rake 'version:bump[minor]'`).

No lint/typecheck configured yet (roadmap: rubocop).
Do not commit without an explicit user request.

## Architectural decisions (do not revert without discussing)

1. **Fail-fast at class definition**: invalid mounts (relative `dest:`,
   duplicate, reserved, >16) raise `ArgumentError` on `mount`/`mount_rw`
   (named params: `source:, dest:, description:`), validated via
   `SecurityBox::Mounts.normalize` (authoritative rules from
   security_box, not duplicated here). The added mount is removed (rollback)
   before re-raising.
2. **Host path expanded at definition** (`File.expand_path` against the boot
   `Dir.pwd`) — same pattern as security_box; deterministic across evals.
3. **Default limits**: `timeout_ms: 30_000` + `fuel_ms: 10_000` (looser than
   the security_box defaults: 2s/fuel 10e9, since agent workloads need more
   headroom).
4. **Fixed description**: the `description` class method raises `ArgumentError`
   when called with an argument; the description is built by
   `build_description` = `FIXED_DESCRIPTION` + "Read-only folders" /
   "Read-write folders" sections (`- \`/guest\` — description`). With no
   mounts, it only mentions `/work`.
5. **Structured return to the model**: hash with `status` ("ok", "error",
   "timeout", "fuel_exhausted", "memory_limit", "sandbox_error"), `value`
   (status ok), `error` (security_box hash with class/message/backtrace, or
   textual message for limits), `stdout`/`stderr` when non-empty.
6. **Subclasses inherit mounts and tools** (the `inherited` hook copies
   `@mounts` and `@tools` — entries/instances are shared — and clears the
   memoized `@configuration`).
7. **Sandbox reused per tool instance** (`@sandbox ||= Sandbox.new(configuration)`).
8. **Bound tools (v2)**: `tools(ToolClass)`, `tools(instance)`, `tools(t1,
   t2, ...)`, `tools([t1, t2])`, `tools("name" => Tool)` (one or several
   pairs; kwargs work too) registers `RubyLLM::Tool`s (fail-fast
   `ArgumentError` at definition: must be a Tool, non-empty name, unique
   name, max `SecurityBox::Rpcs::MAX_RPCS` = 64, never a `CodeMode`
   descendant). The name is derived from the class-name **leaf**
   (`MyApp::Tools::Weather` → `weather`, same algorithm as `tool_name`) —
   the base `RubyLLM::Tool.tool_name` would leak the namespace. The class is
   instantiated once at definition; every call shares that instance. The
   handler is `->(args) { entry.tool.call(**args) }`: `Tool#call` symbolizes
   string keys and validates required/unknown keywords (schema mistakes come
   back as RubyLLM's `{ error: "Invalid tool arguments: ..." }` hash); any
   exception propagates → guest sees `SB::ToolError` (class + message only).
   Non-Hash args raise `ArgumentError` ("expects a hash of arguments").
   Multi-item `tools` calls are all-or-nothing: on any failure the whole
   `@tools` snapshot is restored before re-raising. Called without
   arguments, `tools` returns the bound-tools hash (polymorphic
   reader/DSL).
   Handlers go into `configuration` (`rpcs:`) — excluded from the
   fingerprint by security_box. The description gains a
   "## Host tools (call with SB.call)" section (intro + name/description +
   `- \`param\` (type, required|optional) — desc` lines) only when tools
   exist; the RPC transcript (`Result#rpcs`) is deliberately NOT forwarded
   to the model.
9. **`mcps` (v2.1)**: `mcps(server)`, `mcps(ServerClass)`, `mcps(ServerClass,
   user: ...)`, `mcps(s1, s2, ...)` or arrays — connects
   [RubyLLM::MCP](https://rubyllm.com/next/mcp/) server(s) at definition and
   binds all their tools. Called without arguments, `mcps` returns the
   connected-servers array (polymorphic reader/DSL). Validation is fail-fast:
   every argument must be a
   `RubyLLM::MCP` instance or subclass (classes are auto-instantiated with
   the keyword inputs; inputs with ready instances raise), and
   `RubyLLM::MCP` being undefined (released RubyLLM 2.0) raises a clear
   `ArgumentError`. Server tools bind under `instance.name` when the tool
   responds to `server_name` (MCP tools keep their server/prefixed name),
   else the leaf-only `leaf_tool_name` — **never** `Tool#name` for regular
   tools, because released RubyLLM 2.0's `Tool#name`/`tool_name` uses the
   FULL class name (namespace leaks). A tool whose name is already bound is
   re-bound as `<server_name>_tool`; a name that still collides after
   prefixing raises. Fails fast with a full rollback of `@tools` AND `@mcps`
   on any exception (including server connection errors). Bound servers are
   recorded as `McpEntry` structs (`name`, `mcp`, `instructions`) in `mcps`
   (inherited by subclasses via the `inherited` hook); instructions are
   snapshotted at definition (no network during description builds) and
   rendered in a "## Server notes" description section. Bound MCP tools
   return `RubyLLM::MCP::Result`; `call_bound_tool` normalizes it into
   `{text:, structured:, error:}` for the guest (guarded by
   `defined?(RubyLLM::MCP::Result)`, so the gem still works with RubyLLM 2.0).

## Essential knowledge about the dependencies

### SecurityBox 0.6.0
- `SecurityBox::Sandbox.new(Configuration.build(...)).eval(code)` → `Result`
  (status, value, stdout, stderr, error, fuel_used, duration_ms)
- Mounts: `{host:, guest:, mode:}` — read-only by default; guest path must be
  absolute, normalized, must not collide with `/work`, `/usr`, `/src`, unique,
  max 16
- The host directory must exist at eval time (otherwise `:sandbox_error` with
  a note on stderr) — fails at *runtime*, not at definition
- `SecurityBox::Mounts.normalize` validates everything;
  `InvalidConfiguration`/`ImageMissing` are rescued in `execute` → they become
  `{status: "sandbox_error", error: {...}}`
- Host RPC: `Configuration.build(rpcs: { "name" => callable })` — validated
  by `SecurityBox::Rpcs.normalize` (non-empty unique String names, handlers
  respond to `call`, max 64, `Rpcs::MAX_RPCS`); excluded from the config
  fingerprint. Guest: `SB.call("name", q: "x")` or `SB.call("name", hash)`.
  Handler receives ONE positional arg: the JSON-parsed args (string keys,
  always a Hash unless the guest passed a non-object); return value is JSON
  round-tripped (non-serializable → inspect string); any exception →
  guest-rescuable `SB::ToolError` (class + message, no backtrace); unbound
  name → `SB::UnknownTool`; limits: 1000 calls/eval, 1 MiB per response
  (both → `SB::ToolError`). `Result#rpcs` carries the frozen transcript
  (nil when no calls). RactorPool rejects rpcs (plain Sandbox is fine)
- Performance: ~600ms per eval with a warm cache; ~15s on first compilation
  (cache in `~/.cache/security_box/modules`); `SecurityBox.warmup` pays it up
  front

### RubyLLM 2.0.0
- Tool: `description` (class), `parameter :name, type:, description:, required:`,
  `execute(**kwargs)`; a returned Hash becomes JSON for the model;
  `{ error: ... }` = recoverable failure
- The default `tool_name` uses the FULL class name (`RubyLLM::CodeMode` →
  `ruby_llm--code_mode`) — that is why `CodeMode` overrides it using only the
  leaf
- OpenRouter: `config.openrouter_api_key`;
  `RubyLLM.chat(model: "deepseek/deepseek-v4.1-flash", provider: "openrouter")`
  resolves even if the model is missing from the local models.json (remote
  models.dev lookup)

### Stdlib inside the sandbox (wasm image, Ruby 4.0)
Available: `json`, `date`, `time`, `set`, `securerandom`, `strscan`, `optparse`.
**NOT available**: `csv`, `bigdecimal`, `ostruct`, `matrix`, external gems,
network. When writing prompts/examples, do not assume `require "csv"`.

## Roadmap / next steps

### v1.x improvements
- DSL for configurable limits (`limits timeout_ms:, fuel_ms:, memory_size:`)
- Warn at definition time if the host path does not exist (today it only
  fails at eval)
- `requires_approval` option in RubyLLM for evals (opt-in)
- Guest environment docs (stdlib table) in the main README

### Infra
- CI (GitHub Actions: rspec, Ruby 4.0)
- rubocop + `.rubocop.yml` aligned with the security_box style
- Badge/CI in the README

## Functional reference example

`sample/csv_reader/csv_reader.rb` runs end to end (OpenRouter +
deepseek-v4.1-flash): read-only mount `data/` → `/data`, mount_rw `out/` →
`/workspace`, and a bound `SalesNotes` host tool (called by the guest via
`SB.call("sales_notes", note: ...)`, appends to `out/notes.log`); the model
analyzes the CSV in the sandbox, writes `report.md` to the host and records a
finding through the bound tool. Use it as the template for new samples and for
testing changes to the gem. For MCP integration, `sample/ruby_llm_mcp/` is the
reference: it connects the server built by
`RubyLLM.mcp(url: "https://learn.microsoft.com/api/mcp")` with `mcps` and runs
against the live server (`dry_run.rb` verifies the wiring without spending
LLM tokens).