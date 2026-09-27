# AGENTS.md

Instructions for coding agents working on this repository.

## What this project is

`ruby_llm-code_mode` is a gem exposing the `RubyLLM::CodeMode` tool for
[RubyLLM](https://rubyllm.com): execution of **model-generated** Ruby code
inside the secure [SecurityBox](https://rubygems.org/gems/security_box)
sandbox (ruby.wasm + wasmtime), with host-folder mounts declared via DSL.

- Gem: `ruby_llm-code_mode` v0.1.0, Ruby >= 4.0, MIT
- Namespace: class `RubyLLM::CodeMode` (subclass of `RubyLLM::Tool`)
- Tool name: derived from the last class-name segment (`CsvReader` →
  `csv_reader`) — `tool_name` is overridden to ignore the `RubyLLM::` prefix

## Structure

```
lib/ruby_llm/code_mode.rb      EVERYTHING of the gem (class + DSL + Mount Struct + version)
spec/code_mode_spec.rb         unit specs (DSL, description, configuration, format_result)
spec/integration_spec.rb       integration specs (real sandbox, real wasm)
spec/spec_helper.rb
sample/csv_reader/             functional example (OpenRouter, deepseek-v4.1-flash)
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
6. **Subclasses inherit mounts** (the `inherited` hook copies `@mounts` and
   clears the memoized `@configuration`).
7. **Sandbox reused per tool instance** (`@sandbox ||= Sandbox.new(configuration)`).

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
- Host RPC (basis of v2): `c.rpc "name" => handler` on the builder; guest calls
  `SB.call(name, args)`; `Result#rpcs` carries the transcript; max 1000
  calls/eval
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

### v2 — "Tools" section in the description (priority 1)
- DSL `tool "name" => handler, description: "..."` (or `rpc`) on the class:
  registers host-side handlers the guest calls via `SB.call`
- `build_description` gains a "## Tools" section listing name + description +
  args
- Handlers go into `configuration` (`rpcs:`); excluding them from the
  fingerprint is security_box behavior
- Test the limits: 1000 calls/eval, 1MiB per response

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
`/workspace`; the model analyzes the CSV in the sandbox and writes `report.md`
to the host. Use it as the template for new samples and for testing changes
to the gem.