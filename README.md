> **Alpha stage — active development.** This repository is in its development phase — breaking changes are to be expected at any time. Pin a commit or tag if you depend on it.

# runtime-analysis.nvim

```
╔═══════════════════════════════════════════════╗
║   r u n t i m e - a n a l y s i s . n v i m   ║
╚═══════════════════════════════════════════════╝
```

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Neovim](https://img.shields.io/badge/Neovim-0.10%2B-57A143?logo=neovim&logoColor=white)](https://neovim.io)
[![Lua](https://img.shields.io/badge/Lua-5.1%2FLuaJIT-2C2D72?logo=lua&logoColor=white)](https://www.lua.org)
![Status](https://img.shields.io/badge/status-active%20development-blue)
[![CI](https://github.com/StefanBartl/runtime-analysis.nvim/actions/workflows/ci.yml/badge.svg)](https://github.com/StefanBartl/runtime-analysis.nvim/actions/workflows/ci.yml)

> Pairs with [documentation.nvim](https://github.com/StefanBartl/documentation.nvim) —
> [`documentation.nvim/docs/ECOSYSTEM.md`](https://github.com/StefanBartl/documentation.nvim/blob/main/docs/ECOSYSTEM.md)
> is the architecture this pairing is part of, and it is **not in this
> repository**: one document describes all four pieces
> (`lib.nvim`, documentation.nvim, this plugin, `mdview.nvim`), so the other
> three link to it rather than keeping a copy. documentation.nvim knows what
> exists and is documented; this plugin knows what actually happens when it
> runs.
>
> [`docmap-desktop`](https://github.com/StefanBartl/docmap-desktop) is the
> third leg — the same static × runtime join, read outside Neovim entirely,
> for anyone not sitting in the editor.

## Table of Contents

- [Overview](#overview)
- [Installation](#installation)
- [Commands](#commands)
- [Setup](#setup)
- [Telemetry](#telemetry)
- [Stall detection](#stall-detection)
- [Integration with documentation.nvim](#integration-with-documentationnvim)
- [The static × runtime join](#the-static--runtime-join)
- [What's not here yet](#whats-not-here-yet)
- [Where this is going](#where-this-is-going)
- [Dependencies](#dependencies)

## Overview

Runtime truth, paired with documentation.nvim's static truth. Three features
today: an in-editor HTTP request runner, `runtime-analysis.telemetry` — opt-in
call counting and usage statistics, moved here from lib.nvim — and
`runtime-analysis.startup`, which finds out what is blocking Neovim's main
loop.

## Installation

Requires Neovim 0.10+ (`vim.system`) and
[`lib.nvim`](https://github.com/StefanBartl/lib.nvim). `curl` on `PATH` for
the request runner.

<details open>
<summary><b>lazy.nvim</b></summary>

```lua
{
  "StefanBartl/runtime-analysis.nvim",
  lazy = false,  -- telemetry auto-instrumentation (opts.telemetry) needs to
                 -- be live before sibling plugins load, to catch their own
                 -- lazy-load moment -- see "Telemetry" below. Request-runner-
                 -- only usage works just as well cmd-lazy-loaded instead:
                 -- cmd = { "RARequest", "RASend" },
  dependencies = { "StefanBartl/lib.nvim" },
  opts = {},
}
```
</details>

<details>
<summary><b>vim.pack</b> (Neovim 0.12+, built in)</summary>

```lua
vim.pack.add({
  { src = "https://github.com/StefanBartl/lib.nvim" },
  { src = "https://github.com/StefanBartl/runtime-analysis.nvim" },
})

require("runtime-analysis").setup({})
```
</details>

<details>
<summary><b>mini.deps</b></summary>

```lua
local add, now = MiniDeps.add, MiniDeps.now
add({
  source = "StefanBartl/runtime-analysis.nvim",
  depends = { "StefanBartl/lib.nvim" },
})
-- `now`, not `later`: telemetry auto-instrumentation needs to be live
-- before sibling plugins load, the same reason the lazy.nvim block above
-- uses `lazy = false` rather than a lazy trigger.
now(function()
  require("runtime-analysis").setup({})
end)
```
</details>

<details>
<summary><b>packer.nvim</b></summary>

```lua
use({
  "StefanBartl/runtime-analysis.nvim",
  requires = { "StefanBartl/lib.nvim" },
  config = function()
    require("runtime-analysis").setup({})
  end,
})
```
</details>

<details>
<summary><b>paq-nvim</b> / manual <code>rtp</code></summary>

```lua
require("paq")({
  "StefanBartl/lib.nvim",
  "StefanBartl/runtime-analysis.nvim",
})

-- paq does no lazy-loading and runs no config hooks:
require("runtime-analysis").setup({})
```
</details>

## Commands

The request runner. No browser, no server, no CORS, no token — the cheap
first version `ECOSYSTEM.md` calls for specifically, because none of those
problems exist for a request Neovim itself sends via `curl`. Full reference:
[`docs/COMMANDS.md`](docs/COMMANDS.md); every keymap, usercmd and autocmd
(there are no keymaps — every entry point is a command; the handful of
autocmds are opt-in telemetry/usage-tracking plumbing, not user-facing):
[`docs/BINDINGS.md`](docs/BINDINGS.md).

```vim
:RA request
```

Opens a new buffer, one request per buffer, in the same shape VS Code's
REST Client / IntelliJ's HTTP Client already use:

```http
POST https://api.example.com/users
Content-Type: application/json
Authorization: Bearer abc123

{"name": "Alice"}
```

`METHOD url` on the first non-blank line, `Name: value` headers, a blank
line, then an optional body — everything after the blank line, verbatim.
One header name is a shorthand: `Auth: Bearer <token>` or
`Auth: Basic <user>:<pass>` resolve into a real `Authorization` header,
base64-encoding Basic credentials for you.

```vim
:RA send
```

Run from inside that buffer: parses it, sends it, and shows the response
(status, headers, body) in a persistent split beside it. **Non-blocking** —
the editor stays responsive while curl runs, a pending "→ sending ..."
placeholder shows immediately, and `:RA cancel` discards whatever comes
back (curl itself keeps running to completion in the background; only its
result is discarded — see `docs/COMMANDS.md` for why a real process kill
is not attempted here). Firing a second `:RA send` before the first
replies supersedes it the same way — no queue, no "already in flight"
refusal. The response pane is reused across sends rather than opening a
new split every time, and sending a request never steals focus away from
the buffer you're editing — the whole point is edit, send, glance at the
response, edit again. A JSON response is pretty-printed and gets real
`json` syntax/folding; `:RA yank` copies just the body, headers and status
left out.

A `# @expect status 200` comment anywhere in a block turns a send into a
smoke test — checked once the response arrives, a mismatch (or a transport
failure) replaces the quickfix list with one entry, never auto-opened; a
match is a plain notify. Deliberately narrow: one directive, one thing it
checks, not a general assertion language.

Two request-body shapes beyond a plain JSON/text body, both VS Code REST
Client's own conventions:

```http
POST https://api.example.com/graphql
X-Request-Type: GraphQL
Content-Type: application/json

query GetUser($id: ID!) {
  user(id: $id) { name }
}

{"id": "42"}
```

**GraphQL** — `X-Request-Type: GraphQL` (consumed, never sent to the
server) marks the body as query text, optionally followed by a blank line
and a JSON variables object; `:RA send` builds the real
`{"query": ..., "variables": {...}}` payload before it goes out.

```http
POST https://api.example.com/upload
Content-Type: multipart/form-data; boundary=----X

------X
Content-Disposition: form-data; name="title"

My title
------X
Content-Disposition: form-data; name="file"; filename="1.png"
Content-Type: image/png

< ./1.png
------X--
```

**Multipart/form-data** — a `< ./relative/path` line as a part's own
content means "read this local file's real bytes", resolved relative to
the request buffer's own directory (or the cwd, for an ad-hoc `:RA
request` scratch buffer). Full reasoning for both, including `:RA
export`'s own handling: [`docs/COMMANDS.md`](docs/COMMANDS.md).

Built via [`lib.nvim.bindings.usercmd.composer`](https://github.com/StefanBartl/lib.nvim) —
`:RA` is one compound verb, `<Tab>`-completed, the same shape `:DocMap` and
`:MDView` already use. `:RARequest`/`:RASend` also still work, unchanged, as
flat aliases for the two commands above — this plugin's oldest, most-used
surface, kept alongside `:RA` rather than replaced by it.

**More than one request per buffer**, `###`-separated, the way both sibling
tools already work:

```http
GET https://api.example.com/users

###

POST https://api.example.com/users
Content-Type: application/json

{"name": "Bob"}
```

`:RA send` parses and sends whichever block the cursor is in (or nearest
above it) — never the whole buffer, never a picker. A committed `.http` or
`.rest` file (both resolve to the `http` filetype — `.rest` via this
plugin's own `ftdetect/`, `.http` natively in Neovim) works exactly the
same way opened directly with `:e`, so a project's whole request
collection can live in one versioned file.

```vim
:RA history
```

Every send is recorded — method, url, status, timestamp, per project — and
`:RA history` opens a `vim.ui.select` picker (whichever picker UI you
already have configured) to reopen one as a fresh request buffer.
**Request-only, deliberately**: no headers, no body, on either side — a
header is very often where the real secret actually lives, and a response
can be large and contain secrets of its own. `:RA history clear` empties
the current project's history.

```vim
:RA env dev
```

`{{baseUrl}}/users/:id` in a request buffer resolves against the selected
environment, read from two per-project JSON files at the project root —
`http-client.env.json` (shared, safe to commit) and
`http-client.private.env.json` (gitignored — the file a real token belongs
in). With no argument, `:RA env` offers every name either file defines via
`vim.ui.select`. Resolution happens exactly once, right before a request is
handed to curl — request history and the "sending ..." placeholder both
keep the literal `{{token}}`, never the value it resolved to. Full
reasoning: [`docs/COMMANDS.md`](docs/COMMANDS.md).

```vim
:RA import
:RA export
```

`:RA import` parses a `curl` command line — the system clipboard by
default, or a visual/line-range selection's own lines — into a new
request buffer; every API's own docs and every browser's "copy as cURL"
already produce exactly this shape. `:RA export` is the reverse: yanks the
`###` block under the cursor as a shareable `curl` command to the unnamed
register. Neither resolves `{{var}}` placeholders — the identical trap
`:RA env` closes applies to sharing too.

```vim
:RA provenance vim.notify
```

"Who wrapped this function," right now — exact for this plugin's own
telemetry wraps (named by namespace), best-effort for anyone else's (any
number of plugins monkey-patch `vim.notify`): a `debug.getinfo` source
location, honestly labeled as an inference rather than a certainty. Full
reasoning: [`docs/COMMANDS.md`](docs/COMMANDS.md).

```vim
:RA inspect runtime-analysis.telemetry
```

Walks a live `package.loaded` table and renders it: functions (with
upvalue counts and source location), nested tables (their own shape),
metatables, and what a direct key *shadows* through `__index`. `:RA
provenance` above answers "who wrapped this one function"; this answers
"what does this whole module actually contain, right now" — cycle-safe,
`__index` reported but never called (a pure read, zero side effects on
the code inspected). `<Tab>`-completes against whatever is actually
loaded in this session. Full reasoning: [`docs/COMMANDS.md`](docs/COMMANDS.md).

```vim
:RA usage start
:RA usage
:RA usage stop
```

Which of your own keymaps and typed commands you actually press — opt-in,
local-only, and the one feature here that records *what the person did*
rather than *what the code did*. `:RA usage start` wraps `vim.keymap.set`
so every function-callback mapping registered from then on counts its own
presses, plus a `CmdlineLeave` hook for typed commands; `:RA usage` reports
current counts, `:RA usage stop` ends collection. Built on
`runtime-analysis.telemetry` itself, pointed at the editor instead of code.
Full reasoning: [`docs/COMMANDS.md`](docs/COMMANDS.md).

```vim
:RA loaded snapshot documentation
:RA loaded snapshots documentation
```

`runtime-analysis.loaded` reads `package.loaded` live — every function
directly on a module's table right now, not what the source merely
declares. `:RA loaded snapshot <prefix> [name]` persists that read for
every currently-loaded module under `<prefix>` (itself, plus anything
`prefix .`-prefixed) as a named snapshot, so it can be viewed later or from
a different process entirely — documentation.nvim's `:DocMap serve` server
mode is the consumer this was built for, since a browser tab has no live
`package.loaded` of its own to read. `:RA loaded snapshots <prefix>` lists
what's saved for a prefix, newest first. Full reasoning:
[`docs/FEATURES/LOADED.md`](docs/FEATURES/LOADED.md).

### `:RA startup …`

| Command | What it does |
|---|---|
| `:RA startup start` | Watch for main-loop stalls; report after 12s. |
| `:RA startup watch` | Same, but keep measuring until `:RA startup report`. |
| `:RA startup report` | Stop measuring and show the timeline. |
| `:RA startup probe` | Print (and yank) the `--cmd` line that measures a startup. |

See [Stall detection](#stall-detection) for what the output means.

## Setup

```lua
require("runtime-analysis").setup({
  split = "vsplit",           -- default; "split" for a horizontal one
  request_filetype = "http",  -- default
  deps_popup = true,          -- default
  telemetry = { ... },        -- opt-in; see Telemetry below
})
```

Four top-level keys, and that is the whole list.

| Key | Default | What it decides |
|---|---|---|
| `split` | `"vsplit"` | Where the response pane opens relative to the request buffer. `"split"` for a horizontal one. |
| `request_filetype` | `"http"` | Filetype set on a new `:RARequest` buffer. `http` rather than a plugin-specific name, because VS Code's REST Client and IntelliJ's HTTP Client already claim it and this buffer's syntax matches theirs — so existing highlighting for either tool works here unmodified. |
| `deps_popup` | `true` | The one-time "which CLI tools does this plugin want, and why" popup on the first `setup()` after install. `false` disables it for this plugin specifically, in the spec itself — no `vim.g` needed. |
| `telemetry` | absent | Auto-instrument every plugin as it loads. Absent means no auto-instrumentation at all, the same as never calling `telemetry.auto()`. See [Telemetry](#telemetry). |

**A misspelled key gets one warning, not silence.** `setup()` validates its
keys before merging anything and names the closest real one — `deps_popups`
comes back as *unknown, did you mean "deps_popup"?* Fail-open by design: it
warns and continues, never blocks `setup()`. The same check runs on
`telemetry.new()` and the lazy.nvim adapter's own options, which is where it
matters most, since those tables are deeper.

Without it a typo'd option vanishes into whatever the default already was,
with nothing anywhere saying the key was never read — which is the failure
this exists for, not tidiness.

## Telemetry

`runtime-analysis.telemetry` — opt-in call counting and usage statistics
for any Lua/Neovim plugin, moved here from lib.nvim. `:RATelemetry` is
registered by the same `setup()` call above; see
[`lua/runtime-analysis/telemetry/README.md`](lua/runtime-analysis/telemetry/README.md)
for the full API (`wrap`/`wrap_loaded`, `auto()`, persistence, Markdown/
browser reports, a sortable/filterable HTML dashboard, the `:RATelemetry`
subcommands). Pass `telemetry = {...}`
in `setup(opts)` to auto-instrument every plugin as it loads — the one
plugin-manager adapter shipped is lazy.nvim's (see that README section for
why no others are). lib.nvim itself keeps a thin caller,
`lib.strategies.telemetry_wrap`, for instrumenting its own `require("lib")`
aggregate specifically — everything else in this module is generic.

Reading a namespace does not need an editor session: `nvim --headless -l
scripts/telemetry.lua report <namespace>` (or `export <namespace> <path>`,
`.md` for Markdown, `.pdf` for PDF via [pdfport.nvim](https://github.com/StefanBartl/pdfport.nvim)
— optional dependency, found on the runtimepath the same way lib.nvim is —
anything else for JSON) reads straight off disk via `telemetry.load()`, no
live instance required — useful for CI, a cron job, or "what did last week
look like" without opening Neovim at all.

## Stall detection

`runtime-analysis.startup` answers "why did Neovim just freeze for half a
second", including during startup — where the usual tools cannot help.

### Why not `--startuptime` or `:profile`

`nvim --startuptime` stops writing at the first screen redraw. The freeze
people actually complain about tends to arrive *after* that, so the log ends
before the interesting part.

`:profile` instruments Vimscript and Lua calls, and is therefore blind to
libuv callbacks — which is exactly where filesystem work, subprocesses and LSP
message handling live. A `vim.fn.system(...):wait()` inside an autocommand
does not show up as anything.

### How it works

A libuv timer measures **its own lateness**. If it asks to run every 20ms and
comes back 900ms late, the loop was blocked for 900ms — no matter what blocked
it: Lua, C, a subprocess, the OS. Nothing needs instrumenting, and nothing can
hide from it.

That alone only gives you a symptom, so every event that could plausibly
explain a block is stamped on the same clock: each lazy.nvim plugin load,
`VimEnter`, `VeryLazy`, `LspAttach` and LSP progress. A `STALL` line covers
`[at - blocked, at]`, so the events listed directly above it are the suspects.

Plugin lines carry lazy's own load time **and why it loaded**, which is usually
the part that cracks a case:

```
  +  0.68 s  event   VeryLazy
  +  0.89 s  ***** STALL  blocked    209 ms  (from +0.68 s)
  +  1.03 s  plugin  sandbox.nvim (65 ms)  <- VeryLazy
  +  1.08 s  plugin  gopath.nvim (62 ms)  <- VeryLazy
  +  2.50 s  plugin  telescope.nvim (74 ms)  <- require 'telescope' from init.lua
```

`<- VeryLazy` means the spec asked for it. `<- require '<mod>' from <file>`
means some other file pulled the plugin in and defeated its own lazy-loading —
and only the second kind is a bug you can fix. A plugin declaring
`cmd = "Telescope"` and still loading at startup looks perfectly innocent in
`:Lazy`; this is where it becomes visible.

### Measuring a freeze you can reproduce

```vim
:RA startup start     " watches for 12s, then reports
:RA startup watch     " watches until you ask for the report
:RA startup report    " stop and show the timeline
```

The report arrives as a notification and is written to `ra-startup.log` in the
current directory.

### Measuring startup itself

The timer has to be ticking before your config is sourced, which a lazily
loaded plugin cannot arrange for itself. Use the bootstrap probe:

```sh
nvim --cmd "luafile /path/to/runtime-analysis.nvim/probe/startup.lua" file.lua
```

`:RA startup probe` prints that line with the path filled in and yanks it, so
there is nothing to retype.

The probe puts the plugin on `package.path` from its own location — no
runtimepath, no plugin manager, no configuration involved — and hands over to
the module. Options can be passed ahead of it:

```sh
nvim --cmd "lua vim.g.ra_startup = { duration_ms = 30000, stall_ms = 200 }"      --cmd "luafile /path/to/runtime-analysis.nvim/probe/startup.lua" file.lua
```

### Options

| Option | Default | Meaning |
|---|---|---|
| `interval_ms` | `20` | How often the timer asks to run. |
| `stall_ms` | `80` | Only lateness at or above this counts as a stall. |
| `duration_ms` | `12000` | Auto-report after this long; `0` measures until stopped. |
| `log_file` | `"ra-startup.log"` | Written on report; `""` writes none. |
| `notify` | `true` | Show the report as a notification. |

### Lua API

```lua
local startup = require("runtime-analysis.startup")

startup.start({ duration_ms = 0 })  -- measure until told otherwise
startup.is_running()                --> boolean
local lines, count, total_ms = startup.lines()
startup.report()                    -- stop, notify, write the log
startup.reset()                     -- drop everything collected
startup.probe_command()             --> the --cmd line, path filled in
```

### Reading the numbers

Two things worth knowing before drawing conclusions from a single run:

- **Startup timing scatters.** Runs of an identical config vary by hundreds of
  milliseconds, mostly from filesystem cache and, on Windows, the AV filter
  driver. Compare medians of three runs, not single numbers.
- **A stall is not always the plugin named above it.** The line is the leading
  suspect, not a verdict — a load time of 40ms under a 300ms block means
  something else contributed too.

## Integration with documentation.nvim

`M.open_request(lines)` is this plugin's one public integration surface —
written against a small named interface from the start, per
`documentation.nvim/docs/ECOSYSTEM.md` §7's own stated rule, rather than another plugin
reaching into this one's internal files. documentation.nvim's `:DocBrowse`
Endpoints mode is the first consumer: pressing `gs` on a route it found by
static analysis calls `require("runtime-analysis").open_request({"METHOD
path", ""})` — a soft dependency (`pcall(require, "runtime-analysis")`),
absent with a clear message when this plugin is not installed.

Deliberately not an immediate send: a route's path (`/users/:id`) is
relative and may contain unfilled `:param`s — genuinely nothing
documentation.nvim's static analysis could send correctly on its own — so
the method and path are pre-filled and the reader completes the base URL
(and any params) before running `:RASend` themselves.

## The static × runtime join

**Shipped.** documentation.nvim's `:DocBrowse telemetry` mode joins this
plugin.s counts against its static analysis — the design that scoped it called
it "Mode 7"; it landed as the **eighth** entry in the real `MODES` list, since
Endpoints took position seven first (see `ECOSYSTEM.md` step 8 for that
renumbering). `:DocBrowse loaded` — the declared-vs-loaded diff,
[`docs/FEATURE_LOG.md`](docs/FEATURE_LOG.md) — followed as the ninth.

The same join now also answers outside Neovim entirely:
[`docmap-desktop`](https://github.com/StefanBartl/docmap-desktop) runs
documentation.nvim's standalone binary as a subprocess and serves its
`/api/telemetry`/`/api/loaded` routes over a real HTTP origin, so a project
opened in that app shows the same Telemetry and Loaded panels a live
Neovim session would — real data when this plugin has collected any for
that project's namespace, an honest "no host"/"no data" message otherwise.

## What's not here yet

**The queue is not in this repository.** Since 2026-08-20 there is one plan
for all three — `documentation.nvim`, `docmap-desktop` and this one — because
the same task used to appear in five documents in three different states:
[`docmap-desktop/docs/PLAN.md`](https://github.com/StefanBartl/docmap-desktop/blob/main/docs/PLAN.md),
split into quick wins, medium and large.

## Where this is going

- [`docs/FEATURE_LOG.md`](docs/FEATURE_LOG.md) — the decision record behind
  everything that has shipped — what, and why.
- [`docs/IDEAS.md`](docs/IDEAS.md) — ideas that only exist *between* plugins:
  runtime-analysis × documentation.nvim × mdview.nvim × lib.nvim.
- [`documentation.nvim/docs/ECOSYSTEM.md`](https://github.com/StefanBartl/documentation.nvim/blob/main/docs/ECOSYSTEM.md)
  — **the architecture, and it is not in this repository.** Where docs, static
  analysis and runtime each belong, and the argument for why this plugin is
  separate from documentation.nvim rather than a module inside it. One document
  for all four pieces; the other three link to it.
- [`doc/runtime-analysis.txt`](doc/runtime-analysis.txt) — `:help
  runtime-analysis`.

## Dependencies

- Neovim 0.10+ (`vim.system`)
- [lib.nvim](https://github.com/StefanBartl/lib.nvim) — `lib.nvim.net.curl`'s
  `fetch_raw`/`fetch_raw_blocking` for the request runner (this plugin is
  the reason those exist: the HTTP status code and response headers were
  not previously exposed by that module at all), `usercmd.composer` for
  `:RA`, `progress` for the sending/cancel indicator and telemetry's own
  reports, `fs.project_key` + `cache.disk` for request history (and
  telemetry's own persistence), `fs.find_root` + `fs.json` for environment
  files (`:RA env`), plus `git`, `ui.kit`, `usercmd`, `notify` and
  `autocmd`.
- `curl` on PATH.
- [mdview.nvim](https://github.com/StefanBartl/mdview.nvim) — optional,
  soft dependency: renders a telemetry report as a live browser tab.

Run `:checkhealth runtime-analysis` to verify all of the above on your
system. `curl` is additionally declared in
[`docs/install.json`](docs/install.json), parsed by lib.nvim's
[`deps` module](https://github.com/StefanBartl/lib.nvim/blob/main/lua/lib/nvim/deps/README.md)
— a popup explains it's missing (and that only `:RASend` needs it) the
first time `setup()` runs after installing this plugin; `:Lib deps show
runtime-analysis.nvim` repeats it any time. Disable it **right in this
plugin's own spec**:
`require("runtime-analysis").setup({ deps_popup = false })`.
`vim.g.lib_nvim_deps_disable_first_run = true` (every plugin) /
`vim.g.lib_nvim_deps_disabled_plugins = { "runtime-analysis.nvim" }` also
still work, for turning it off without touching any plugin's config.

**Dev-only:** [documentation.nvim](https://github.com/StefanBartl/documentation.nvim)
generates `docs/map/`, this repository's own module map, adopted per that
project's [`docs/REUSE.md`](https://github.com/StefanBartl/documentation.nvim/blob/main/docs/REUSE.md)
— not a runtime dependency, nothing here requires it installed as a plugin.
`nvim --headless -l scripts/gen_map.lua` regenerates it; `--check` (the CI
gate, `.github/workflows/ci.yml`'s `map` job) verifies it is current and
drift-free without writing anything. `git config core.hooksPath scripts/hooks`
installs a local pre-commit hook running the same check. This repository's own
map is published at **<https://stefanbartl.github.io/runtime-analysis.nvim/>**;
[docs/map/overview.md](docs/map/overview.md) is the same tree as Markdown,
rendered on GitHub. History, Telemetry and Loaded need a local server and say
so on the published copy — every other tab works there in full.

## License

MIT — see [LICENSE](LICENSE).
