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
the "not a general profiler" rejection.

Run it yourself for numbers specific to your own machine, rather than
trusting a committed table:

```bash
nvim --headless -l scripts/bench_overhead.lua
nvim --headless -l scripts/bench_overhead.lua --calls=1000000
```

- **Module:** `scripts/bench_overhead.lua`
- **Docs:** [`lua/runtime-analysis/telemetry/README.md`](../../lua/runtime-analysis/telemetry/README.md)
  "Off costs nothing — literally" section; decision record in
  [`docs/FEATURE_LOG.md`](../FEATURE_LOG.md) (§3.7).

## The startup require tree as a flamegraph

`telemetry/startup.lua` wraps the global `require` and times every cache
miss against a stack, so each entry carries `depth`, `total_ms` and a
`self_ms` with its children subtracted out. That is already a flamegraph —
width is time, depth is nesting, and a parent's uncovered strip is its own
work. `:RATelemetry startup` renders it as a sorted table, which answers
"where did the time go" and flattens the one dimension that answers "what
did it go *inside*".

`:RATelemetry flamegraph [path]` draws the same report as an SVG.

- **Module:** `telemetry/renderers/flamegraph.lua` (`M.tree`, `M.svg`),
  `telemetry/report_file.lua` (`M.flamegraph_path`)
- **Usercmds:** `:RATelemetry flamegraph [path]`
  ([bindings](../BINDINGS.md))
- **Needs:** nothing. `images.nvim` draws it in the terminal when it is
  installed; otherwise the file goes to the system opener, and it is an
  ordinary SVG either way.

### The tree is rebuilt, not recorded

`startup.lua` stores no parent pointer, only a depth — and it does not need
one. Entries are appended when a load *begins*, so the list is a pre-order
traversal, and a pre-order sequence plus a depth per node determines the
tree uniquely. `M.tree` walks it with a stack indexed by depth: the same
stack the recorder used, reconstructed afterwards.

That is also why the renderer reads `report.order` rather than
`report.modules`. `modules` is sorted by self time and may be cut by `top`,
and either of those destroys the reconstruction — sorting loses the
pre-order, `top` drops whole subtrees. Both would still produce a
plausible-looking picture, which is the dangerous part; `order` exists so
they cannot.

### Why SVG

It is text, so it diffs and costs no image library to produce, and it stays
sharp at any zoom — which matters here, because the interesting frames are
the narrow ones. `images.nvim` converts it to PNG through its own cached
SVG path when it has to be drawn in a terminal, so nothing is lost by not
rasterizing here.

The document carries an explicit light background rather than a transparent
one. Its job is to leave the editor, and every consumer that rasterizes it
renders transparency as whatever sits behind — which in a terminal is
usually black, under dark text.

### One colour per module root, in hex

A flamegraph where every frame has its own colour shows nothing. Hashing
the module *root* instead means a plugin's whole subtree shares a colour,
which answers "which block is this" before a label is read, and the hash
makes it stable across runs.

The colours are fixed hex values from a small palette, and that is a bug
fix rather than a preference. The first version computed `hsl()` from the
hash — correct in a browser, **solid black** through ImageMagick's librsvg
delegate, which does not implement `hsl()` in a `fill` and falls back to
the initial value. That delegate is the path `images.nvim` uses, so the
primary consumer would have received black boxes with black text. Found by
rasterizing the output and looking at it, which is the only way this class
of bug is ever found.

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

## Instrumenting your own Neovim config, not just plugins

- **Module:** `telemetry/`
- **Config:** `opts.telemetry.extra` — explicit targets, beside `opts.telemetry.plugins`

`opts.telemetry.plugins` can only ever describe what a plugin manager
resolves. Your own config is not one of those things — no repo, no spec,
and usually several unrelated root prefixes rather than one `main` — yet it
is often the most interesting Lua tree in the session, and the only one
whose dead code nobody else will ever report on.

`opts.telemetry.extra` is that target, stated outright by the caller:

```lua
require("runtime-analysis").setup({
  telemetry = {
    extra = {
      {
        namespace = "nvim-config",
        mains = { "config", "bindings", "plugins", "autocmds", "lsp" },
        profile_args = true,
      },
    },
  },
})
```

It is then an ordinary namespace everywhere: `:RATelemetry nvim-config`,
`coverage`, `compare`, `snapshot`, `export`, the HTML dashboard, and
`:RATelemetry setup|full nvim-config`.

**Wrapped at VimEnter by default, and that default is the point.** When
`runtime-analysis.setup()` runs it is normally still *inside*
`lazy.setup()` — before the config's later phases (options, autocmds, LSP,
keymaps) have required anything. Since `wrap_loaded()` only ever sees what
is already in `package.loaded`, wrapping at that moment would produce a
nearly empty namespace: the failure this default exists to prevent, not a
theoretical one. `wrap_at = "setup"` (already-loaded targets) and
`"manual"` (command-only) override it per target.

**One instance per target, not per prefix.** Several `mains` share one
namespace and therefore one cache file, so counts add up instead of two
instances clobbering each other — the collision `telemetry.new()` warns
about.

**No lazy.nvim required.** `extra` resolves purely through `package.loaded`;
the lazy.nvim adapter covers `plugins` only. A namespace is created only
once at least one of its `mains` is actually loaded, so a target whose
prefixes are all absent leaves nothing behind rather than an empty
namespace.

`deep` defaults to **true** here, unlike a plugin's façade-first default: a
config prefix has no façade worth wrapping instead — `require("bindings")`
is not where a config's functions live.

**Selecting it later:** a config has no repo, so `:RATelemetry setup <ns>` /
`:RATelemetry full <ns>` (which take a namespace) are how it is named for a
re-wrap. That is also the fix when a module first required *after* the wrap
— a keymap handler pulled in on first press — shows zero calls.
