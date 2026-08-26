# runtime-analysis.nvim — Commands, Autocommands & Keymaps

Hand-maintained, not generated — this small a surface (one compound verb,
two flat aliases, one second compound command, no keymaps, a handful of
opt-in autocommands) is small enough that a generator (the way
[documentation.nvim's own `docs/BINDINGS.md`](https://github.com/StefanBartl/documentation.nvim/blob/main/docs/BINDINGS.md)
is built from its live keymap table) would cost more than it saves. Update
this file by hand whenever a command's shape changes.

## User commands

All four are registered unconditionally by `require("runtime-analysis").setup()`
— none is independently opt-in the way telemetry's own auto-instrumentation
(`opts.telemetry`) is.

| Command | Args | Description |
| --- | --- | --- |
| `:RA request` | none | Opens a new scratch buffer, `filetype = opts.request_filetype` (default `http`), pre-filled with a `GET https://` template. Always one fresh, unnamed buffer per call — for a real, committed file with several requests, open it directly with `:e` instead (see `###` below). |
| `:RA send` | none | Parses and sends the `###`-block the cursor is in (or nearest above it) — see `###` below; a single-block buffer (no `###` at all) behaves exactly as before that existed. Sends via `lib.nvim.net.curl.fetch_raw` (`runtime-analysis.runner.run_async`) and shows status/headers/body in a persistent split (`runtime-analysis.view`) that never steals focus. **Non-blocking** — a "sending..." placeholder shows immediately, a real `lib.nvim.progress` indicator if available, and a second send before the first replies supersedes it. A JSON body is pretty-printed with real `json` filetype/folding. |
| `:RA yank` | none | Yank just the last response's body (not status/headers) to the unnamed register. Warns, does not error, when there is no response yet. |
| `:RA cancel` | none | Discards the in-flight request's eventual result and shows `✗ cancelled`. A *logical* cancel, not a process kill — see `docs/COMMANDS.md` for why. Warns, does not error, when nothing is in flight. |
| `:RA history` | none | `vim.ui.select` picker over this project's recorded sends (method/url/status/timestamp only — see `docs/COMMANDS.md`), newest first; picking one reopens it via `open_request`. |
| `:RA history clear` | none | Clears this project's recorded history. No confirmation prompt. |
| `:RA env [name]` | environment name, optional, `<Tab>`-completed | With `name`, selects it as the active environment `{{var}}` placeholders resolve against; with none, `vim.ui.select` over every name the project's env files define. See `docs/COMMANDS.md` for the file format. |
| `:RA import` | none (or a range, e.g. `'<,'>RA import`) | Parses a `curl` command line — from the system clipboard, or the given range's lines — into a new request buffer. |
| `:RA export` | none | Yanks the `###` block under the cursor as a shareable `curl` command line to the unnamed register. |
| `:RA provenance <path>` | dotted path, e.g. `vim.notify` | Who wrapped this function right now — exact for this plugin's own telemetry wraps, best-effort (a `debug.getinfo` source location) for anyone else's. See `docs/COMMANDS.md`. |
| `:RA startup start` | none | Watches the main loop for stalls and reports after 12s. A libuv timer measures its *own* lateness, so a block is caught wherever it comes from -- including libuv callbacks, which `:profile` cannot see. |
| `:RA startup watch` / `:RA startup report` | none | The same measurement, kept running until you ask for the timeline. The report puts plugin loads (with lazy's load time **and** load reason), `VimEnter`, `VeryLazy`, `LspAttach` and LSP progress on one clock. |
| `:RA startup probe` | none | Prints and yanks the `--cmd` command line that measures the startup itself -- the timer has to tick before the config is sourced, which a lazily loaded plugin cannot arrange for itself. |
| `:RA inspect <module>` | a `package.loaded` key, `<Tab>`-completed live | Walks a live module table: functions, tables, metatables, what's shadowed through `__index`. See `docs/COMMANDS.md`. |
| `:RA usage` | none | Report keymap/command press counts collected since `:RA usage start`. See `docs/COMMANDS.md`. |
| `:RA usage start` / `:RA usage stop` | none | Start/stop counting — opt-in, local-only, records what you pressed rather than what the code did. |
| `:RA loaded snapshot <prefix> [name]` | module prefix, optional snapshot name | Persists a named capture of every currently-loaded module under `<prefix>` (`runtime-analysis.loaded`). See `docs/COMMANDS.md`. |
| `:RA loaded snapshots <prefix>` | module prefix | Lists saved loaded snapshots for `<prefix>`, newest first. See `docs/COMMANDS.md`. |
| `:RARequest` | none | Flat alias for `:RA request` — see below for why both exist. |
| `:RASend` | none | Flat alias for `:RA send`. |
| `:RATelemetry [args]` | see below | Opt-in call counting and usage statistics for any plugin. Full reference: [`lua/runtime-analysis/telemetry/README.md`](../lua/runtime-analysis/telemetry/README.md). |

Built via [`lib.nvim.usercmd.composer`](https://github.com/StefanBartl/lib.nvim/blob/main/lua/lib/nvim/usercmd/composer/README.md)
— the same verb-first shape `:DocMap`, `:MDView` and `:Replace` already use
(`<Tab>` after `:RA ` completes `request`/`send`/`yank`/`cancel`/`history`/
`env`/`import`/`export`/`provenance`/`inspect`/`usage`/`loaded`; `:RA
history <Tab>` completes `clear`, `:RA env <Tab>` completes whatever names
this project's env files currently define, `:RA inspect <Tab>` completes
whatever is actually in `package.loaded` right now, `:RA usage <Tab>`
completes `start`/`stop`, `:RA loaded <Tab>` completes `snapshot`/
`snapshots`). `:RATelemetry` stays a
second, separate compound command rather than folding under `:RA telemetry
...`, the same split documentation.nvim draws between `:DocMap`
(writes/verifies) and `:DocBrowse` (only reads) — here between "runs a
request" and "reports on what already ran".

**Why the flat `:RARequest`/`:RASend` still exist alongside `:RA request`/
`:RA send`.** They are this plugin's oldest, most-referenced public surface;
keeping them costs four lines and means nobody's own keymap to either name
breaks on a rename. See [`lua/runtime-analysis/bindings/usrcmds.lua`](../lua/runtime-analysis/bindings/usrcmds.lua)'s
own doc-comment for the full reasoning.

### `###`: multiple requests per buffer, and real files

`runtime-analysis.parse.split` cuts a buffer into `###`-separated blocks
(the marker line itself excluded from both sides); `parse.block_at`
resolves which block a cursor line belongs to. `:RA send`/`:RASend` always
run this — a single-block buffer (no `###` at all) is one block covering
everything, so nothing behaves differently than before `###` support
existed. A real, committed `.http`/`.rest` file works identically once
opened with `:e` — `*.http` resolves to filetype `http` natively in
Neovim, `*.rest` via this plugin's own [`ftdetect/runtime-analysis.lua`](../ftdetect/runtime-analysis.lua).

### GraphQL and multipart bodies

Two request-body shapes `:RA send`/`:RA export` both understand beyond
plain JSON/text — docs/ROADMAP.md §2.6, VS Code REST Client's own
conventions. `X-Request-Type: GraphQL` marks a body as query text (+
optional blank-line-separated JSON variables), turned into the real
`{"query": ..., "variables": {...}}` payload
([`lua/runtime-analysis/graphql.lua`](../lua/runtime-analysis/graphql.lua)).
A `Content-Type: multipart/form-data; boundary=...` body with `< ./path`
part references gets those paths resolved to real file bytes when sent,
or turned into curl's own `-F "field=@path"` flags on export — never
inlined as shell text
([`lua/runtime-analysis/multipart.lua`](../lua/runtime-analysis/multipart.lua)).
Full reasoning: `docs/COMMANDS.md`.

### Request history

`runtime-analysis.history` records method/url/status/timestamp for every
send, per project (`lib.nvim.fs.project_key()`), via `lib.nvim.cache.disk`
— no headers, no body, on either side (a header is very often where the
real secret actually lives). Capped at `history.MAX_ENTRIES` (200), oldest
dropped first. Full reasoning: `docs/COMMANDS.md`'s own section on it.

### Variables and environments (`:RA env`)

`{{baseUrl}}` in a request buffer's url, header values or body resolves
against the environment selected by `:RA env <name>` — session-scoped, not
persisted across restarts. Names and values come from two per-project JSON
files at the project root (`SHARED_FILE`/`PRIVATE_FILE` in `runtime-analysis.env`),
merged per name with the private file's own keys winning on overlap. Full
reasoning, file format and the "trap" this exists to avoid:
`docs/COMMANDS.md`'s own section on it.

### Response assertions (`# @expect status N`)

A comment line anywhere in a `###` block (`# @expect status 200` or
`// @expect status 200`), checked once `:RA send`'s response arrives — see
`docs/COMMANDS.md` for the full reasoning. A match is a plain notify; a
mismatch (including a transport failure) replaces the quickfix list with
one entry, never auto-opened. Module:
[`lua/runtime-analysis/assertions.lua`](../lua/runtime-analysis/assertions.lua).

### curl import/export (`:RA import` / `:RA export`)

`:RA import` reads a `curl` command line — from a real range invocation's
selected lines, or the system clipboard otherwise — and parses it
(`lua/runtime-analysis/curl.lua`, a real if bounded argument parser) into
a new request buffer via `open_request`. `:RA export` is the reverse:
formats the `###` block under the cursor as a shareable command line,
yanked to the unnamed register. Neither resolves `{{var}}` placeholders —
see `docs/COMMANDS.md` for the full reasoning, the same trap `:RA env`'s
own section states.

### Wrapper provenance (`:RA provenance <path>`)

"Who wrapped this function," exact for this plugin's own telemetry wraps
(`telemetry.registry.info`, the same shared wrap layer every instance goes
through), best-effort for anyone else's (a `debug.getinfo` source
location). New top-level module:
[`lua/runtime-analysis/provenance.lua`](../lua/runtime-analysis/provenance.lua).
`<path>` completes level by level (composer argtype `RA_PROVENANCE_PATH`),
against loaded state only -- Tab never triggers a `require`.
See `docs/COMMANDS.md` for the full reasoning.

### Live module inspection (`:RA inspect <module>`)

Walks a live `package.loaded[module]` table: functions (upvalue counts,
source location), nested tables (their own shape, recursed with a
cycle-safe `seen` set and a cosmetic `max_depth` cap of 3), metatables,
and which direct keys *shadow* a table `__index`. A metatable's `__index`
is reported, never called — a pure read, zero side effects on the code
inspected. lib.nvim's own roadmap turned this idea down as `:LibInspect`
and named a future tool as the right home; this is that tool. New
top-level module: [`lua/runtime-analysis/inspect.lua`](../lua/runtime-analysis/inspect.lua).
See `docs/COMMANDS.md` for the three design questions this resolves.

### Keymap and command usage (`:RA usage`)

The one feature here that records *what the person did* rather than *what
the code did* — a config's own mappings and typed commands, opt-in and
local-only. `:RA usage start` wraps `vim.keymap.set` so every
function-callback mapping registered from then on counts its own presses,
and installs a `CmdlineLeave` hook that counts a typed command once it
actually commits (an `<Esc>`-aborted line counts nothing). Built on
`runtime-analysis.telemetry` itself, the same wrap mechanism §7.2's
cost-vs-use report already reads, pointed at editor input instead of code.
See `docs/COMMANDS.md` for the honest limits (only mappings set after
`start`, only function-callback rhs, no per-buffer split). Module:
[`lua/runtime-analysis/usage.lua`](../lua/runtime-analysis/usage.lua).

### Persisted loaded snapshots (`:RA loaded snapshot` / `:RA loaded snapshots`)

Named, persisted captures of `runtime-analysis.loaded`'s live
`package.loaded` read, so it can be viewed later, or from a process that
never itself loaded the code in question — documentation.nvim's `:DocMap
serve` Loaded Analysis panel is the consumer this was built for. `:RA
loaded snapshot <prefix> [name]` scopes the walk to `prefix` (and anything
`prefix .`-prefixed), the same scoping `wrap_loaded(prefix)` already uses;
`:RA loaded snapshots <prefix>` lists what's saved, newest first. Same
`lib.nvim.cache.disk` storage and retention/eviction policy as telemetry's
own named snapshots, on a separate cache-key prefix so the two never
collide. See `docs/COMMANDS.md` and
[`docs/FEATURES/LOADED.md`](FEATURES/LOADED.md) for the full reasoning.
Module: [`lua/runtime-analysis/loaded.lua`](../lua/runtime-analysis/loaded.lua).

### `:RATelemetry` subcommands

| Invocation | Does |
| --- | --- |
| `:RATelemetry` | report across every live instance, in a kit float |
| `:RATelemetry <ns>` | report for one namespace |
| `:RATelemetry start [ns]` | every instance, or just one |
| `:RATelemetry stop [ns]` | every instance, or just one |
| `:RATelemetry reset [ns]` | back up (prompted once for a directory, only if anything exists), then drop the aggregate — every instance, or just one |
| `:RATelemetry flush [ns]` | write now and keep recording — every instance, or just one. The periodic flush, `stop` and `VimLeavePre` all write anyway; this buys certainty at a chosen moment without ending the run to get it. |
| `:RATelemetry disable [ns]` | stop + persist "off" across restarts |
| `:RATelemetry enable [ns]` | clear a persisted disable, resume now |
| `:RATelemetry disabled` | list namespaces currently disabled |
| `:RATelemetry coverage` | which wrapped functions were never called |
| `:RATelemetry export [path]` | JSON, or Markdown if `path` ends `.md` |
| `:RATelemetry export-all <dir>` | one Markdown file per namespace found on disk into `<dir>` — not limited to this session's live instances |
| `:RATelemetry open [ns]` | render + open (`report_style`: `auto`/`kit`/`preview-tab`/`mdview`/`file`/`html`) |
| `:RATelemetry compare [ns] [days]` | "this window vs the one before it" (default 7 days) — newly-hot/gone-cold/changed functions |
| `:RATelemetry startup [top]` | which module a plugin's startup cost sits in, as a waterfall. Opt-in via `autostart()` from this plugin's own lazy.nvim `init` hook — see the telemetry README for why `init` and not `init.lua`. |
| `:RATelemetry cost` | startup cost vs. call count per namespace, worst (expensive, underused) first — joins `startup` and every live instance's own `resolved_modules()` on real module paths, never a name guess. |
| `:RATelemetry snapshot <ns> [name]` | save a named, device-tagged capture of `ns`'s current aggregate |
| `:RATelemetry snapshots <ns>` | list `ns`'s saved snapshots, newest first |
| `:RATelemetry snapshot-compare <ns> <a> <b>` | diff two named snapshots' call counts directly (not a calendar window like `compare`) |
| `:RATelemetry setup [ns]` | back up + reset + re-wrap + (re)start — every configured target, or just one. The only way to select an `extra` target such as your own config (`:RATelemetry setup nvim-config`). |
| `:RATelemetry full [ns]` | same, forcing `profile_args` + `timing` on regardless of the target's own policy |
| `:RATelemetryStartAll` | standalone alias for `:RATelemetry start` (bare) |
| `:RATelemetryStopAll` | standalone alias for `:RATelemetry stop` (bare) |
| `:RATelemetryResetAll` | standalone alias for `:RATelemetry reset` (bare) — same backup prompt |
| `:RATelemetrySetupAll` | bare form of `:RATelemetry setup`: for every target `opts.telemetry.plugins`/`opts.telemetry.extra` configures that is currently loaded — back up existing data (prompted once for a directory, only if anything exists), reset, re-wrap (picks up any submodule loaded after the first wrap), start with that target's own configured `profile_args`/`timing`. See `docs/COMMANDS.md`. |
| `:RATelemetrySetupAllFull` | bare form of `:RATelemetry full` — same as `:RATelemetrySetupAll`, forcing `profile_args`/`timing` on for every target regardless of its own configured policy |

`<Tab>` after `start `/`stop `/`reset `/`open `/`compare ` completes
namespaces only; `compare`'s own third token (a day count) is not
completed, and neither `startup` nor `cost` take a namespace at all
(`startup`'s second token is a `top` count; `cost` takes no arguments).

## Keymaps

**None.** This plugin sets zero global keymaps and none inside its own
buffers either — every entry point is a command. A request buffer is edited
with whatever mappings the reader already has for the `http` filetype (VS
Code REST Client / IntelliJ HTTP Client conventions, since `request_filetype`
defaults to `http` for exactly that reason); the response split is
`nomodifiable` scratch content with no bindings of its own beyond native
Vim navigation.

## Autocommands

None user-facing — nothing here watches buffer or window events, and every
*action* is triggered directly by a command. Five real registrations exist,
all opt-in plumbing behind telemetry/usage tracking rather than something a
keymap could ever collide with:

| Event | Module | Group | Does |
| --- | --- | --- | --- |
| `VimLeavePre` | `telemetry/init.lua` | `ra_telemetry_<namespace>`, one per live instance | Flush persisted counters on exit (`stop()` is deliberately not called — the process is ending). |
| `VimEnter` | `telemetry/init.lua` | same, per instance | Checks the "data has been sitting a while" reminder outside a periodic flush. |
| `User LazyLoad` | `telemetry/lazy.lua` | `runtime_analysis_telemetry_lazyload` | Auto-instrumentation catch-up: wraps + starts an instance the moment lazy.nvim finishes loading a plugin listed in `opts.telemetry.plugins`. |
| `UIEnter` (`once = true`) | `telemetry/startup.lua` | `runtime_analysis_startup` | Stops startup-cost timing — only fires if `telemetry.startup.autostart()` was wired into the caller's own lazy.nvim `init` hook. |
| `CmdlineLeave` | `usage.lua` | `runtime_analysis_usage` | Counts a typed command by name, unless the cmdline was aborted — active only between `:RA usage start` and `:RA usage stop`. |

None of these exist unless the corresponding feature is actually enabled: a
setup with `opts.telemetry` unset and `:RA usage start` never run installs
none of them.

## Health check

`:checkhealth runtime-analysis` — see [`lua/runtime-analysis/health.lua`](../lua/runtime-analysis/health.lua)
for exactly what it reports (Neovim version, `curl`, required lib.nvim
modules, live telemetry instances, this project's history entry count,
defined environments, whether keymap/command usage tracking is running,
cache directory, optional mdview.nvim and lib.nvim.progress).

## Global-surface collision check

Checked against the personal config's `docs/NOTES/PersonelPlugins/BINDINGS/Usercmds/*.md`
collection (2026-08-03): `RA`, `RARequest`, `RASend` and `RATelemetry` are
unique — no other personal plugin registers any of the four.
