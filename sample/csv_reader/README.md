# sample/csv_reader

Functional example of `RubyLLM::CodeMode`: an agent that analyzes a CSV with
model-generated Ruby code running inside the SecurityBox sandbox, using
[OpenRouter](https://openrouter.ai) (`deepseek/deepseek-v4.1-flash`).

```
sample/csv_reader/
├── csv_reader.rb   the agent script
├── data/           sales.csv — mounted read-only at /data
└── out/            report.md — mounted read-write at /workspace
```

## Run

From the project root, with `OPENROUTER_API_KEY` set:

```bash
bundle exec ruby sample/csv_reader/csv_reader.rb
```

## What it demonstrates

- `mount`: `data/` is exposed at `/data` read-only — the sandbox can parse the
  CSV but cannot modify it.
- `mount_rw`: `out/` is exposed at `/workspace` read-write — the agent saves
  `report.md` there, and the host reads it back after the chat ends.
- The tool description the model receives: fixed "How to use" section plus the
  Read-only/Read-write folder sections listing both mounts.
- The sandbox costs are paid up front with `CsvReader.warmup`, so each
  evaluation takes a few hundred milliseconds.

## Sandbox environment

The sandbox image runs Ruby 4.0 with a minimal stdlib. Verified availability:

- available: `json`, `date`, `time`, `set`, `securerandom`, `strscan`, `optparse`
- **not** available: `csv`, `bigdecimal`, `ostruct`, `matrix`, third-party gems, network

That is why the model in this example parses `sales.csv` by hand instead of
`require "csv"`. Keep this in mind when writing prompts for sandboxed agents.

## Expected output

The script prints the warm-up, the assistant's summary, and then the contents
of `sample/csv_reader/out/report.md` — the file the model wrote through the
read-write mount. Re-running the sample overwrites the report.