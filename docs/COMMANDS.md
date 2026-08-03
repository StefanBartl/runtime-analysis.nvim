# Commands

One compound verb, two flat aliases, and one second compound command —
split along the same line documentation.nvim's own `docs/COMMANDS.md` draws
between `:DocMap` and `:DocBrowse`: `:RA` **does** something to a request,
`:RATelemetry` **reports** on what has already run.

None exists until `setup()` runs — `require("runtime-analysis").setup()`
registers all four unconditionally; there is no `opts.command_name` to
rename them yet, unlike the sibling plugins, because nothing here has hit a
collision that would motivate one (see the Global-surface collision check in
[`docs/BINDINGS.md`](BINDINGS.md)).

---

## `:RA request` (alias: `:RARequest`)

Opens a new scratch buffer (`buftype = "acwrite"`, `filetype =
opts.request_filetype`, default `http`), pre-filled with:

```
GET https://
```

Cursor lands at the end of that first line. One request per buffer — see
[`docs/ROADMAP.md`](ROADMAP.md) §1.2 for why `###`-separated multi-request
files (both VS Code's REST Client and IntelliJ's HTTP Client support this)
are not attempted yet.

`M.open_request(lines)` (the same function this command calls with no
argument) is also this plugin's public integration surface — see
`docs/IDEAS.md` and the module doc-comment in
[`lua/runtime-analysis/init.lua`](../lua/runtime-analysis/init.lua) for how
documentation.nvim's `:DocBrowse` Endpoints mode calls it with a pre-filled
`METHOD path` instead of the default template.

## `:RA send` (alias: `:RASend`)

Run from inside a request buffer. Parses the buffer's lines
(`runtime-analysis.parse`) into `{ method, url, headers, body }`, sends it
via `lib.nvim.net.curl.fetch_raw_blocking` (`runtime-analysis.runner`), and
renders `STATUS status_text`, sorted headers, a blank line, then the body
into a persistent split (`runtime-analysis.view`).

**Blocking.** The editor waits for the response — see `docs/ROADMAP.md` §1.1
for the planned async version. A parse error or a transport failure (bad
host, timeout) reports via `vim.notify` and nothing is sent; an HTTP error
status (404, 500, …) is not an error at all and renders as a normal
response.

The response split is reused across sends (looked up by buffer name, not
held in a module variable, so a stale reference after `:bwipeout` or a
`:source` during development cannot happen) and never steals focus from the
request buffer — the workflow is edit, send, glance, edit again, not
"switch to the response and back."

### Why `:RARequest`/`:RASend` exist as separate flat commands, not only `:RA request`/`:RA send`

`:RA`, built via `lib.nvim.usercmd.composer`, is the verb-first shape
`NEW_PROJECT.md`'s own checklist prefers and every sibling plugin
(`:DocMap`, `:MDView`, `:Replace`) already uses. But `:RARequest`/`:RASend`
predate `:RA` and are this plugin's most-referenced public surface; keeping
both costs four lines in
[`bindings/usrcmds.lua`](../lua/runtime-analysis/bindings/usrcmds.lua) and
means a user's own keymap to either flat name never breaks on a rename.
Both call exactly the same handlers — there is no behavioral difference to
document twice.

## `:RATelemetry [subcommand] [namespace]`

Opt-in call counting and usage statistics for any Lua/Neovim plugin. A
second, separate compound command rather than `:RA telemetry ...` — see
"Why `:RATelemetry` is not `:RA telemetry ...`" below for the reasoning.
Registered by the same `setup()` call as `:RA` above, but its own module
(`runtime-analysis.telemetry`) registers nothing on `require` alone —
see that module's own extensive README
([`lua/runtime-analysis/telemetry/README.md`](../lua/runtime-analysis/telemetry/README.md))
for the full API this command is a thin front-end over: instances, scoping
(`wrap`/`wrap_loaded`/`wrap_fn`), the lifecycle (`start`/`stop`/`unwrap`),
persistent enable/disable, argument profiling, report metadata, and the
mdview browser bridge.

Subcommand table: [`docs/BINDINGS.md`](BINDINGS.md#ratelemetry-subcommands).

**Only a genuinely empty or recognized argument acts.** An unknown
subcommand reports what it expected rather than falling through to a
default — the same rule documentation.nvim's `:DocMap` follows for the
identical reason: a typo silently doing the wrong thing (rewriting a report,
resetting data) is worse than a typo doing nothing.

---

## Why `:RATelemetry` is not `:RA telemetry ...`

One verb per plugin is the default `NEW_PROJECT.md`'s checklist prefers, but
not an absolute rule — the checklist itself names `replacer.nvim`'s
`:Replace` + `:Surround` split as a documented exception when a second
concern doesn't belong under the first verb. Telemetry is that case here:
it is a large, independent surface (11 subcommands, namespace completion,
its own extensive README) about a plugin's *runtime history* in general,
not specifically about the request runner `:RA` is named for. Nesting it as
`:RA telemetry start markdown.nvim` buries a namespace argument three
levels deep for no real gain, and documentation.nvim already established
the precedent this mirrors: `:DocMap` and `:DocBrowse` are two commands,
not `:DocMap browse ...`, split along the same "does something" vs.
"reports on something" line used here.

## What is not a command

- **No keymaps, no autocommands.** See [`docs/BINDINGS.md`](BINDINGS.md) —
  every entry point here is one of the four commands above.
- **`M.open_request`/`M.setup` are Lua API, not commands.** Documented in
  [`lua/runtime-analysis/init.lua`](../lua/runtime-analysis/init.lua)'s own
  module doc-comment and in `docs/IDEAS.md` §1 as the integration surface
  another plugin calls into directly.
