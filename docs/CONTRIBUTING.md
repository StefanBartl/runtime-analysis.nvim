# Contributing to runtime-analysis.nvim

Thank you for your interest! Bugs, ideas and questions are welcome in the
[issue tracker](https://github.com/StefanBartl/runtime-analysis.nvim/issues);
pull requests very welcome.

Read [`IDEAS.md`](IDEAS.md) before proposing a feature. Its "deliberately not"
section already carries the argument against a fair number of reasonable-looking
additions, and knowing which side of that line an idea falls on saves the
conversation.

## Getting the repository into a session

Clone it and either symlink the checkout into your plugin directory or add it
to the runtime path directly:

```lua
vim.opt.rtp:prepend("/path/to/runtime-analysis.nvim")
require("runtime-analysis").setup({})
```

[lib.nvim](https://github.com/StefanBartl/lib.nvim) has to be on the runtime
path too, and `curl` on `PATH` if you are touching the request runner.

If you are working on the telemetry, load the checkout eagerly — instrumentation
that arrives after the plugin it wants to measure has nothing to measure, and a
lazy-loaded dev copy will look broken for exactly that reason.

## Ground rules

- Lua only, idiomatic Neovim Lua. 2-space indentation, `stylua.toml` decides
  the rest.
- **Measure; do not infer.** This plugin exists to be the counter-check to a
  static analyzer. Anything it reports has to come from something that actually
  happened — a counter, a timer, a live table — and anything that cannot be
  measured is labelled as an inference, the way `:RA provenance` labels a wrap
  it did not make itself. A confident number nobody measured is worse than no
  number.
- **The measurement must not become the cost.** Instrumentation is opt-in and
  its overhead is part of its contract; a feature that meaningfully slows the
  session it is observing has invalidated its own readings. Benchmark it —
  [`FEATURES/BENCH.md`](FEATURES/BENCH.md) is in this repository for a reason.
- **Data on disk is the interface.** documentation.nvim and docmap-desktop read
  this plugin's telemetry and loaded data, never its internals. The one call
  across that boundary is `M.open_request`. Keep the file formats stable, and
  treat a change to one as a change to a public API — see [`api.md`](api.md).
- **Nothing blocks the loop being measured.** The request runner is
  non-blocking, and the stall detector is a libuv timer measuring its own
  lateness precisely so that it sees blocks it did not cause. A synchronous
  call anywhere in the measuring path defeats the instrument.
- **A namespace is readable without a live instance.** Telemetry can be read
  straight off disk, headless, for CI or a cron job. A feature that only works
  inside an interactive session loses that.
- Commands are registered through `lib.nvim.bindings.usercmd.composer`. There
  are no keymaps, deliberately, and `docs/BINDINGS.md` is hand-maintained on
  the argument that the surface is small enough for that to stay true.
- Descriptive commit messages.

## Project layout

| Path | Contains |
| --- | --- |
| `lua/runtime-analysis/telemetry/` | Call counting: instrumentation, namespaces, on-disk format, snapshots |
| `lua/runtime-analysis/startup/` | Stall detection — the libuv lateness timer and the plugin-load attribution |
| `lua/runtime-analysis/bindings/` | The `:RA` and `:RATelemetry` route trees, and the autocommands |
| `lua/runtime-analysis/config/` | The five `setup()` keys, their defaults and validation |
| `lua/runtime-analysis/@types/` | Shared type definitions |
| `scripts/gen_map.lua` | The generated module map — this is one of the two repositories in the collection that ships one |
| `doc/`, `docs/` | The vimdoc, and everything the README links to |
| `TESTS/` | The spec suite |

## Adding a command

1. Put the measurement in the area module it belongs to; the command layer
   renders, the area measures.
2. Route it in `lua/runtime-analysis/bindings/`, with completion over every
   closed argument set. `:RA` runs something, `:RATelemetry` reports on what has
   already run — a new verb goes on the side of that split it actually belongs
   to.
3. If it writes anything to disk, treat the format as an interface: another
   process may read it.
4. Add a spec under `TESTS/`.
5. Document it in [`commands.md`](commands.md), [`BINDINGS.md`](BINDINGS.md)
   and the matching page under [`FEATURES/`](FEATURES/README.md).
6. Add the decision to [`FEATURE_LOG.md`](FEATURE_LOG.md) — what shipped and
   the trade-off behind it. If the idea came out of [`IDEAS.md`](IDEAS.md),
   move the entry here in full rather than striking it through where it stood;
   that is what keeps the log load-bearing instead of a changelog.

## Adding an instrumentation

1. It is opt-in, always, and off by default.
2. Measure its own overhead and write the number down. See the ground rules.
3. Make the namespace readable from disk with no live instance.
4. Report its state in `health.lua` — the telemetry section is what someone
   reads when a count looks wrong.

## Tests

`TESTS/` is a headless spec suite.

```
nvim --headless -u NONE -l TESTS/run.lua
```

Exit 0 is a pass. [GitHub Actions](../.github/workflows/ci.yml) runs it plus
luacheck, regenerates the module map, and force-pushes `ci-verified` to the
tested commit so dependent repositories can pin a known-good state.

## Workflow

1. Fork the repository.
2. Branch as `feature/<name>`.
3. Make the change, add a spec, update the affected pages under `docs/` and the
   feature log.
4. Open a PR with a clear description of what changed and why.
