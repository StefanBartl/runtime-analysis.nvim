# Features

A [`documentation.nvim/docs/FEATURES_FORMAT.md`](https://github.com/StefanBartl/documentation.nvim/blob/main/docs/FEATURES_FORMAT.md)-shaped
catalog of this plugin's own signature features — for
`documentation.nvim`'s own Features tab to render, when this repo's own
generated map is opened, the same way it renders that plugin's own
`docs/FEATURES/`. This folder is the *user-facing* catalog: what a feature
is, which module and command are behind it, today —
[`docs/ROADMAP.md`](../ROADMAP.md)/[`docs/FINISHED.md`](FINISHED.md)
stay the *decision record* (why something was built the way it was, what
commit shipped it), a different document for a different reader.

Deliberately not exhaustive — the point of this folder is a real,
representative sample, not full coverage of every command this plugin
has. [`README.md`](../../README.md) and [`docs/COMMANDS.md`](../COMMANDS.md)
remain the complete reference.

## Files

- **[REQUESTS.md](REQUESTS.md)** — the HTTP request runner: the
  `# @expect` smoke-test directive, GraphQL/multipart body shorthand,
  environment-scoped `{{var}}` resolution.
- **[TELEMETRY.md](TELEMETRY.md)** — `runtime-analysis.telemetry`:
  zero-cost-when-stopped instrumentation, reading a namespace without a
  live instance, named/dated snapshots for comparing two points in time.
- **[LOADED.md](LOADED.md)** — `runtime-analysis.loaded`: the
  loaded-vs-declared live read documentation.nvim joins against its own
  IR, and persisted snapshots of it for cold viewing outside the session
  that took them.
- **[BENCH.md](BENCH.md)** — `runtime-analysis.bench`: timed comparisons
  between candidate functions, deliberately not built on telemetry's own
  wrap/count machinery.
