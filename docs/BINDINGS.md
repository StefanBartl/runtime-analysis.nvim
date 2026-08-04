# runtime-analysis.nvim — Commands, Autocommands & Keymaps

Hand-maintained, not generated — this small a surface (one compound verb,
two flat aliases, one second compound command, no keymaps or autocommands)
is small enough that a generator (the way
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
| `:RARequest` | none | Flat alias for `:RA request` — see below for why both exist. |
| `:RASend` | none | Flat alias for `:RA send`. |
| `:RATelemetry [args]` | see below | Opt-in call counting and usage statistics for any plugin. Full reference: [`lua/runtime-analysis/telemetry/README.md`](../lua/runtime-analysis/telemetry/README.md). |

Built via [`lib.nvim.usercmd.composer`](https://github.com/StefanBartl/lib.nvim/blob/main/lua/lib/nvim/usercmd/composer/README.md)
— the same verb-first shape `:DocMap`, `:MDView` and `:Replace` already use
(`<Tab>` after `:RA ` completes `request`/`send`/`yank`/`cancel`/`history`/
`env`/`import`/`export`; `:RA history <Tab>` completes `clear`, `:RA env
<Tab>` completes whatever names this project's env files currently
define). `:RATelemetry` stays a
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
files at the project root (`runtime-analysis.env.SHARED_FILE`/`.PRIVATE_FILE`),
merged per name with the private file's own keys winning on overlap. Full
reasoning, file format and the "trap" this exists to avoid:
`docs/COMMANDS.md`'s own section on it.

### curl import/export (`:RA import` / `:RA export`)

`:RA import` reads a `curl` command line — from a real range invocation's
selected lines, or the system clipboard otherwise — and parses it
(`lua/runtime-analysis/curl.lua`, a real if bounded argument parser) into
a new request buffer via `open_request`. `:RA export` is the reverse:
formats the `###` block under the cursor as a shareable command line,
yanked to the unnamed register. Neither resolves `{{var}}` placeholders —
see `docs/COMMANDS.md` for the full reasoning, the same trap `:RA env`'s
own section states.

### `:RATelemetry` subcommands

| Invocation | Does |
| --- | --- |
| `:RATelemetry` | report across every live instance, in a kit float |
| `:RATelemetry <ns>` | report for one namespace |
| `:RATelemetry start [ns]` | every instance, or just one |
| `:RATelemetry stop [ns]` | every instance, or just one |
| `:RATelemetry reset [ns]` | every instance, or just one |
| `:RATelemetry disable [ns]` | stop + persist "off" across restarts |
| `:RATelemetry enable [ns]` | clear a persisted disable, resume now |
| `:RATelemetry disabled` | list namespaces currently disabled |
| `:RATelemetry coverage` | which wrapped functions were never called |
| `:RATelemetry export [path]` | JSON, or Markdown if `path` ends `.md` |
| `:RATelemetry open [ns]` | render + open externally (`report_style`: `auto`/`kit`/`mdview`/`file`) |

`<Tab>` after `start `/`stop `/`reset `/`open ` completes namespaces only.

## Keymaps

**None.** This plugin sets zero global keymaps and none inside its own
buffers either — every entry point is a command. A request buffer is edited
with whatever mappings the reader already has for the `http` filetype (VS
Code REST Client / IntelliJ HTTP Client conventions, since `request_filetype`
defaults to `http` for exactly that reason); the response split is
`nomodifiable` scratch content with no bindings of its own beyond native
Vim navigation.

## Autocommands

**None.** Nothing here watches buffer or window events; every action is
triggered directly by a command.

## Health check

`:checkhealth runtime-analysis` — see [`lua/runtime-analysis/health.lua`](../lua/runtime-analysis/health.lua)
for exactly what it reports (Neovim version, `curl`, required lib.nvim
modules, live telemetry instances, this project's history entry count,
cache directory, optional mdview.nvim and lib.nvim.progress).

## Global-surface collision check

Checked against the personal config's `docs/NOTES/PersonelPlugins/BINDINGS/Usercmds/*.md`
collection (2026-08-03): `RA`, `RARequest`, `RASend` and `RATelemetry` are
unique — no other personal plugin registers any of the four.
