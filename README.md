```
╔═══════════════════════════════════════════════╗
║   r u n t i m e - a n a l y s i s . n v i m   ║
╚═══════════════════════════════════════════════╝
```

[![CI](https://github.com/StefanBartl/runtime-analysis.nvim/actions/workflows/ci.yml/badge.svg)](https://github.com/StefanBartl/runtime-analysis.nvim/actions/workflows/ci.yml)
![Neovim 0.10+](https://img.shields.io/badge/Neovim-0.10%2B-57A143?logo=neovim&logoColor=white)
![Lua](https://img.shields.io/badge/Lua-5.1%2FLuaJIT-2C2D72?logo=lua&logoColor=white)

> Pairs with [documentation.nvim](https://github.com/StefanBartl/documentation.nvim) —
> that plugin's `docs/ECOSYSTEM.md` is the architecture this pairing is part
> of. documentation.nvim knows what exists and is documented; this plugin
> knows what actually happens when it runs.

## Table of Contents

- [Overview](#overview)
- [Commands](#commands)
- [Setup](#setup)
- [Telemetry](#telemetry)
- [Integration with documentation.nvim](#integration-with-documentationnvim)
- [What's not here yet](#whats-not-here-yet)
- [Where this is going](#where-this-is-going)
- [Dependencies](#dependencies)

## Overview

Runtime truth, paired with documentation.nvim's static truth. Two features
today: an in-editor HTTP request runner, and `runtime-analysis.telemetry` —
opt-in call counting and usage statistics, moved here from lib.nvim.

## Commands

The request runner. No browser, no server, no CORS, no token — the cheap
first version `ECOSYSTEM.md` calls for specifically, because none of those
problems exist for a request Neovim itself sends via `curl`. Full reference:
[`docs/COMMANDS.md`](docs/COMMANDS.md); every keymap, usercmd and autocmd
(there are no keymaps or autocmds): [`docs/BINDINGS.md`](docs/BINDINGS.md).

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
(status, headers, body) in a persistent split beside it. The response pane
is reused across sends rather than opening a new split every time, and
sending a request never steals focus away from the buffer you're editing —
the whole point is edit, send, glance at the response, edit again. A JSON
response is pretty-printed and gets real `json` syntax/folding; `:RA yank`
copies just the body, headers and status left out.

Built via [`lib.nvim.usercmd.composer`](https://github.com/StefanBartl/lib.nvim) —
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

## Setup

```lua
require("runtime-analysis").setup({
  split = "vsplit",           -- default; "split" for a horizontal one
  request_filetype = "http",  -- default
})
```

## Telemetry

`runtime-analysis.telemetry` — opt-in call counting and usage statistics
for any Lua/Neovim plugin, moved here from lib.nvim. `:RATelemetry` is
registered by the same `setup()` call above; see
[`lua/runtime-analysis/telemetry/README.md`](lua/runtime-analysis/telemetry/README.md)
for the full API (`wrap`/`wrap_loaded`, `auto()`, persistence, Markdown/
browser reports, the `:RATelemetry` subcommands). Pass `telemetry = {...}`
in `setup(opts)` to auto-instrument every plugin as it loads — the one
plugin-manager adapter shipped is lazy.nvim's (see that README section for
why no others are). lib.nvim itself keeps a thin caller,
`lib.strategies.telemetry_wrap`, for instrumenting its own `require("lib")`
aggregate specifically — everything else in this module is generic.

Reading a namespace does not need an editor session: `nvim --headless -l
scripts/telemetry.lua report <namespace>` (or `export <namespace> <path>`,
`.md` for Markdown, anything else for JSON) reads straight off disk via
`telemetry.load()`, no live instance required — useful for CI, a cron job,
or "what did last week look like" without opening Neovim at all.

## Integration with documentation.nvim

`M.open_request(lines)` is this plugin's one public integration surface —
written against a small named interface from the start, per
`docs/ECOSYSTEM.md` §7's own stated rule, rather than another plugin
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

## What's not here yet

- **Async sending.** `:RASend` blocks until the response arrives — real,
  and fine for a request bounded in seconds, but a genuine limitation for
  a slow endpoint.
- **Request history.** Nothing is saved between sends yet.
- **The static × runtime join** — a planned `:DocBrowse` mode joining
  documentation.nvim's static analysis against telemetry's counts, a
  *different*, later mode than the Endpoints mode already added — is a
  later step in `ECOSYSTEM.md`'s own sequencing, not this one. Both that
  document and the design it points at call it "Mode 7"; it will be the
  **eighth** entry in the real `MODES` list, since Endpoints took position
  seven first.

See [`docs/ROADMAP.md`](docs/ROADMAP.md) for the full, phased backlog behind
this short list.

## Where this is going

- [`docs/ROADMAP.md`](docs/ROADMAP.md) — this plugin's own backlog, phased
  into quick wins / medium / longer-term work, plus documented rejections.
- [`docs/FINISHED.md`](docs/FINISHED.md) — the decision record behind
  everything that has shipped out of `docs/ROADMAP.md` — what, and why.
- [`docs/IDEAS.md`](docs/IDEAS.md) — ideas that only exist *between* plugins:
  runtime-analysis × documentation.nvim × mdview.nvim × lib.nvim.
- [`doc/runtime-analysis.txt`](doc/runtime-analysis.txt) — `:help
  runtime-analysis`.

## Dependencies

- Neovim 0.10+ (`vim.system`)
- [lib.nvim](https://github.com/StefanBartl/lib.nvim) — `lib.nvim.net.curl`'s
  `fetch_raw`/`fetch_raw_blocking` for the request runner (this plugin is
  the reason those exist: the HTTP status code and response headers were
  not previously exposed by that module at all), `usercmd.composer` for
  `:RA`, plus `cache.disk`, `git`, `ui.kit`, `usercmd`, `notify`, `autocmd`
  and `progress` for telemetry.
- `curl` on PATH.
- [mdview.nvim](https://github.com/StefanBartl/mdview.nvim) — optional,
  soft dependency: renders a telemetry report as a live browser tab.

Run `:checkhealth runtime-analysis` to verify all of the above on your
system.
