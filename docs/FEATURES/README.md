# Features

The through-line is one asymmetry. Static analysis can only see what is written
in the text: a function bound as a callback value, or reached through dynamic
dispatch, has no call site naming it — to a parser it does not exist, and the
telemetry sees it run. Everything here exists to be the counter-check to a
static analyzer, not a second one.

Four areas, one command surface: `:RA` runs something, `:RATelemetry` reports
on what has already run.

| Area | Does |
| --- | --- |
| **Requests** — [REQUESTS.md](REQUESTS.md) | `.http` / `.rest` files, several requests per file, `{{var}}` environments split into a committed and a gitignored file, `curl` import and export, a `# @expect status 200` smoke-test directive, GraphQL and multipart bodies. No browser, no server, no CORS, no token — none of those problems exist for a request Neovim sends itself |
| **Telemetry** — [TELEMETRY.md](TELEMETRY.md) | Opt-in call counting for any Lua plugin: which functions ran, how often, with what argument shapes, at what cost. A namespace can be read straight off disk with no live instance — including headless, for CI or a cron job |
| **Loaded** — [LOADED.md](LOADED.md) | What `package.loaded` really contains right now, not what the source declares — plus named snapshots, so a process that never loaded the code can still read the answer |
| **Stalls** — [STARTUP.md](STARTUP.md) | A libuv timer measuring its own lateness, so a block shows up whatever caused it: Lua, C, a subprocess, the OS. Plugin loads carry lazy's load time *and* the reason it loaded, which is usually what cracks the case |

Three more answer a question rather than run a job. `:RA inspect <module>`
walks a live module table — functions, upvalue counts, metatables, what a
direct key shadows through `__index`. `:RA provenance vim.notify` says who
wrapped a function: exact for this plugin's own wraps, honestly labelled as an
inference for anyone else's. `:RA usage` counts which of your own keymaps and
typed commands you actually press — the one feature here that records what the
*person* did rather than what the code did. And [BENCH.md](BENCH.md) times
candidate functions against each other.

Every command, argument by argument, is [../commands.md](../commands.md).

## The static × runtime join

documentation.nvim's `:DocBrowse telemetry` mode joins this plugin's counts
against its static analysis; `:DocBrowse loaded` does the same for the
declared-against-loaded diff. Both read this plugin's data, never its
internals. The one *call* between the two plugins is `M.open_request`, which
`:DocBrowse` Endpoints uses to hand a route over as a request buffer: a small
named surface, a soft dependency, described in [../api.md](../api.md).

The same join also answers outside Neovim entirely:
[docmap-desktop](https://github.com/StefanBartl/docmap-desktop) runs
documentation.nvim's standalone binary as a subprocess and serves its
`/api/telemetry` and `/api/loaded` routes over a real HTTP origin, so a project
opened in that app shows the same Telemetry and Loaded panels a live Neovim
session would.

The architecture behind all of it —
[documentation.nvim/docs/ECOSYSTEM.md](https://github.com/StefanBartl/documentation.nvim/blob/main/docs/ECOSYSTEM.md)
— **is not in this repository.** One document describes all four pieces
(`lib.nvim`, documentation.nvim, this plugin, `mdview.nvim`), so the other
three link to it rather than keeping a copy. The same is true of the queue:
what gets built next lives in one plan for all three repositories,
[docmap-desktop/docs/PLAN.md](https://github.com/StefanBartl/docmap-desktop/blob/main/docs/PLAN.md).

## The catalog

A [`documentation.nvim/docs/FEATURES_FORMAT.md`](https://github.com/StefanBartl/documentation.nvim/blob/main/docs/FEATURES_FORMAT.md)-shaped
catalog of this plugin's own signature features — for
`documentation.nvim`'s own Features tab to render, when this repo's own
generated map is opened, the same way it renders that plugin's own
`docs/FEATURES/`. This folder is the *user-facing* catalog: what a feature
is, which module and command are behind it, today —
[`docs/FEATURE_LOG.md`](../FEATURE_LOG.md) stays the *decision record* (why something was built the way it was, what
commit shipped it), a different document for a different reader.

Deliberately not exhaustive — the point of this folder is a real,
representative sample, not full coverage of every command this plugin
has. [`docs/commands.md`](../commands.md) remains the complete reference.

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
- **[STARTUP.md](STARTUP.md)** — `runtime-analysis.startup`: a libuv timer
  measuring its own lateness, so a main-loop block shows up whatever caused
  it — including during startup, where `--startuptime` and `:profile` both
  give up. Alongside it, `runtime-analysis.startup.profile`: repeated
  `--startuptime` runs averaged into a per-file median, because that tool is
  not wrong, only early, file-shaped and far too noisy to read once.
- **[BENCH.md](BENCH.md)** — `runtime-analysis.bench`: timed comparisons
  between candidate functions, deliberately not built on telemetry's own
  wrap/count machinery.
