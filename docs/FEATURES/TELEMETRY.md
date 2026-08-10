# Telemetry

`runtime-analysis.telemetry` — opt-in call counting for any Lua/Neovim
plugin, cheap enough to leave running for a week rather than switching on
for thirty seconds.

## Zero-cost when stopped

Instrumentation is *installed*, not compiled in: until `t.start()` runs,
the wrapped functions are the original functions — the same objects, not
a nearly-free branch — and `t.stop()` puts them back exactly. This is why
there is no `if enabled then count() end` scattered through a consumer's
own source, and why a plugin author can ship this wired up permanently
rather than deciding per-release whether the cost is worth it.

- **Module:** `telemetry/init.lua` (`M.new`, `inst.start`, `inst.stop`)
- **Config:** `telemetry.new({ namespace = ..., persist = true, ... })`
  — see [`lua/runtime-analysis/telemetry/README.md`](../../lua/runtime-analysis/telemetry/README.md)
  for the full options table.

## Reading a namespace without a live instance

A fresh Neovim process — a `:DocMap check` run analyzing a different
plugin, a CI job, a health check — can read what an *earlier* session
collected, with no instance of its own: `telemetry.load(namespace)`,
`nil` when nothing was ever persisted, distinct from a well-formed empty
table so a caller can tell "never enabled here" from "enabled, zero
calls." The same read works from a CLI with no editor at all:
`nvim --headless -l scripts/telemetry.lua report <namespace>`.

- **Module:** `telemetry/init.lua` (`M.load`), `telemetry/store.lua`
  (`M.load_readonly`)
- **Docs:** [`lua/runtime-analysis/telemetry/README.md`](../../lua/runtime-analysis/telemetry/README.md)
  "Reading without an instance" section.

## Named, dated snapshots

`telemetry.snapshot(namespace, name?)` captures the current aggregate
under a name, independent of the one continuously-overwritten live slot
`telemetry.load()` always reads — the difference between "what does usage
look like right now" and "what did it look like before I started this
refactor." Flushes a live instance first if one exists, so a snapshot
taken mid-session reflects calls not yet written to disk. Retention is
LRU (`telemetry.SNAPSHOT_RETENTION`, default 20 per namespace,
overridable via `opts.snapshot_retention`); the trigger is always
explicit — `:RATelemetry snapshot <ns> [name]` — nothing in this module
ever snapshots on its own.

- **Module:** `telemetry/init.lua` (`M.snapshot`, `M.list_snapshots`,
  `M.load_snapshot`), `telemetry/store.lua` (`M.save_snapshot`,
  `M.evict_old_snapshots`)
- **Usercmds:** `:RATelemetry snapshot <ns> [name]`, `:RATelemetry
  snapshots <ns>`
- **Config:** `opts.snapshot_retention` on `telemetry.new()`.
- **Docs:** [`lua/runtime-analysis/telemetry/README.md`](../../lua/runtime-analysis/telemetry/README.md)
  "Named snapshots" section.

## Measuring the instrumentation's own overhead

`scripts/bench_overhead.lua` — a reproducible, user-runnable benchmark
answering "does turning on telemetry (or one specific feature of it —
timing, argument profiling, `call_tree`, `errors`) actually slow a plugin
down, and by how much", with a measured number instead of an assurance.
Deliberately **not** a runtime feature: nothing here is installed, left
running, or user-toggleable — a one-time script you run and read numbers
from, the same posture a library's README publishing "~200ns per call"
already has. That exclusion is what lets it exist without reopening
`docs/ROADMAP.md` §3.5's "not a general profiler" rejection.

Run it yourself for numbers specific to your own machine, rather than
trusting a committed table:

```bash
nvim --headless -l scripts/bench_overhead.lua
nvim --headless -l scripts/bench_overhead.lua --calls=1000000
```

- **Module:** `scripts/bench_overhead.lua`
- **Docs:** [`lua/runtime-analysis/telemetry/README.md`](../../lua/runtime-analysis/telemetry/README.md)
  "Off costs nothing — literally" section; decision record in
  [`docs/FINISHED.md`](../FINISHED.md) (§3.7).

## The static × runtime join

The reason this plugin exists next to documentation.nvim rather than
folded into it. documentation.nvim's static scan can prove a function is
never called from anywhere it can *see* — never that it is actually dead;
a callback bound as a value, or a call from a sibling repo entirely, looks
identical to genuinely dead code to a pure static read. `telemetry.load()`
answers the one question a static scan structurally cannot: was this
*actually* called. `wrap_loaded()` is what makes the join possible at
all — it resolves a wrapped key back to a real Lua module path
automatically, the same key shape documentation.nvim's own IR uses.

- **Module:** `telemetry/init.lua` (`inst.wrap_loaded`,
  `inst.resolved_modules`)
- **Docs:** [`README.md`](../../README.md) "Integration with
  documentation.nvim" section, documentation.nvim's own
  [`docs/PIPELINE.md`](https://github.com/StefanBartl/documentation.nvim/blob/main/docs/PIPELINE.md)
  "Telemetry" section for the consumer side of the same join.
