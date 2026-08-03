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
| `:RA request` | none | Opens a new scratch buffer, `filetype = opts.request_filetype` (default `http`), pre-filled with a `GET https://` template. One request per buffer. |
| `:RA send` | none | Run from inside a request buffer. Parses it (`runtime-analysis.parse`), sends it via `lib.nvim.net.curl.fetch_raw_blocking` (`runtime-analysis.runner`), and shows status/headers/body in a persistent split (`runtime-analysis.view`) that never steals focus from the request buffer. Blocking — the editor waits for the response. A JSON body is pretty-printed with real `json` filetype/folding. |
| `:RA yank` | none | Yank just the last response's body (not status/headers) to the unnamed register. Warns, does not error, when there is no response yet. |
| `:RARequest` | none | Flat alias for `:RA request` — see below for why both exist. |
| `:RASend` | none | Flat alias for `:RA send`. |
| `:RATelemetry [args]` | see below | Opt-in call counting and usage statistics for any plugin. Full reference: [`lua/runtime-analysis/telemetry/README.md`](../lua/runtime-analysis/telemetry/README.md). |

Built via [`lib.nvim.usercmd.composer`](https://github.com/StefanBartl/lib.nvim/blob/main/lua/lib/nvim/usercmd/composer/README.md)
— the same verb-first shape `:DocMap`, `:MDView` and `:Replace` already use
(`<Tab>` after `:RA ` completes `request`/`send`). `:RATelemetry` stays a
second, separate compound command rather than folding under `:RA telemetry
...`, the same split documentation.nvim draws between `:DocMap`
(writes/verifies) and `:DocBrowse` (only reads) — here between "runs a
request" and "reports on what already ran".

**Why the flat `:RARequest`/`:RASend` still exist alongside `:RA request`/
`:RA send`.** They are this plugin's oldest, most-referenced public surface;
keeping them costs four lines and means nobody's own keymap to either name
breaks on a rename. See [`lua/runtime-analysis/bindings/usrcmds.lua`](../lua/runtime-analysis/bindings/usrcmds.lua)'s
own doc-comment for the full reasoning.

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
modules, live telemetry instances, cache directory, optional mdview.nvim).

## Global-surface collision check

Checked against the personal config's `docs/NOTES/PersonelPlugins/BINDINGS/Usercmds/*.md`
collection (2026-08-03): `RA`, `RARequest`, `RASend` and `RATelemetry` are
unique — no other personal plugin registers any of the four.
