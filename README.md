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

> Pairs with [documentation.nvim](https://github.com/StefanBartl/documentation.nvim):
> it knows what exists and is documented, this plugin knows what actually
> happens when the code runs — the same project, from the two sides that can
> contradict each other.
>
> And with [insights.nvim](https://github.com/StefanBartl/insights.nvim):
> insights reads the source text for what looks unused (imports, symbols,
> metrics); this measures whether it was ever really called. A parser cannot
> see a callback, and a counter cannot see dead text.

**Runtime truth for a Neovim project.** An in-editor HTTP request runner,
opt-in call counting for any Lua plugin (`runtime-analysis.telemetry`), a live
read of what is actually in `package.loaded`, and stall detection that finds
what blocks the main loop — including during startup, where `--startuptime`
and `:profile` both give up.

The through-line is one asymmetry: static analysis can only see what is
written in the text. A function bound as a callback value, or reached through
dynamic dispatch, has no call site naming it — to a parser it does not exist,
and the telemetry sees it run. Everything here exists to be the counter-check
to a static analyzer, not a second one.

---

## Table of contents

- [Quickstart](#quickstart)
- [What it does](#what-it-does)
- [The static x runtime join](#the-static-x-runtime-join)
- [Documentation](#documentation)
- [License](#license)

---

## Quickstart

Requires Neovim **0.10+**, [lib.nvim](https://github.com/StefanBartl/lib.nvim),
and `curl` on `PATH` for the request runner. Other package managers:
[`docs/installation.md`](docs/installation.md).

```lua
{
  "StefanBartl/runtime-analysis.nvim",
  lazy = false,  -- telemetry auto-instrumentation (opts.telemetry) has to be
                 -- live before sibling plugins load, to catch their own
                 -- lazy-load moment. Request-runner-only usage works just as
                 -- well cmd-lazy-loaded: cmd = { "RARequest", "RASend" },
  dependencies = { "StefanBartl/lib.nvim" },
  opts = {},
}
```

Then:

```vim
:RA request
```

A new buffer opens, one request per buffer, in the same shape VS Code's REST
Client and IntelliJ's HTTP Client already use:

```http
POST https://api.example.com/users
Content-Type: application/json
Authorization: Bearer abc123

{"name": "Alice"}
```

`:RA send` from inside it parses the buffer, sends it, and shows status,
headers and body in a split beside it — non-blocking, focus stays where you
are typing. That is the whole loop: edit, send, glance, edit again.

Verify your setup any time with:

```
:checkhealth runtime-analysis
```

---

## What it does

Four areas, one command surface. `:RA` runs something,
`:RATelemetry` reports on what has already run.

| | |
| --- | --- |
| **Requests** — [`FEATURES/REQUESTS.md`](docs/FEATURES/REQUESTS.md) | `.http`/`.rest` files, several requests per file, `{{var}}` environments split into a committed and a gitignored file, `curl` import/export, a `# @expect status 200` smoke-test directive, GraphQL and multipart bodies. No browser, no server, no CORS, no token — none of those problems exist for a request Neovim sends itself. |
| **Telemetry** — [`FEATURES/TELEMETRY.md`](docs/FEATURES/TELEMETRY.md) | Opt-in call counting for any Lua/Neovim plugin: which functions ran, how often, with what argument shapes, at what cost. A namespace can be read straight off disk with no live instance — including headless, for CI or a cron job. |
| **Loaded** — [`FEATURES/LOADED.md`](docs/FEATURES/LOADED.md) | What `package.loaded` really contains right now, not what the source declares — plus named snapshots of it, so a process that never loaded the code can still read the answer. |
| **Stalls** — [`FEATURES/STARTUP.md`](docs/FEATURES/STARTUP.md) | A libuv timer measuring its own lateness, so a block shows up whatever caused it — Lua, C, a subprocess, the OS. Plugin loads carry lazy's load time *and* the reason it loaded, which is usually what cracks the case. |

Three more answer a question rather than run a job. `:RA inspect <module>`
walks a live module table — functions, upvalue counts, metatables, what a
direct key shadows through `__index`. `:RA provenance vim.notify` says who
wrapped a function: exact for this plugin's own wraps, honestly labelled as an
inference for anyone else's. `:RA usage` counts which of your own keymaps and
typed commands you actually press — the one feature here that records what the
*person* did rather than what the code did. And
[`FEATURES/BENCH.md`](docs/FEATURES/BENCH.md) times candidate functions against
each other.

Every command, argument by argument: [`docs/commands.md`](docs/commands.md).

---

## The static x runtime join

**Shipped.** documentation.nvim's `:DocBrowse telemetry` mode joins this
plugin's counts against its static analysis; `:DocBrowse loaded` does the same
for the declared-vs-loaded diff — both read this plugin's data, never its
internals. The one *call* between the two plugins is `M.open_request`, which
`:DocBrowse` Endpoints uses to hand a route over as a request buffer: a small
named surface, a soft dependency, described in [`docs/api.md`](docs/api.md).

The same join also answers outside Neovim entirely:
[`docmap-desktop`](https://github.com/StefanBartl/docmap-desktop) runs
documentation.nvim's standalone binary as a subprocess and serves its
`/api/telemetry` and `/api/loaded` routes over a real HTTP origin, so a
project opened in that app shows the same Telemetry and Loaded panels a live
Neovim session would.

The architecture behind all of it —
[`documentation.nvim/docs/ECOSYSTEM.md`](https://github.com/StefanBartl/documentation.nvim/blob/main/docs/ECOSYSTEM.md)
— **is not in this repository.** One document describes all four pieces
(`lib.nvim`, documentation.nvim, this plugin, `mdview.nvim`), so the other
three link to it rather than keeping a copy. The same is true of the queue:
what gets built next lives in one plan for all three repositories,
[`docmap-desktop/docs/PLAN.md`](https://github.com/StefanBartl/docmap-desktop/blob/main/docs/PLAN.md).

---

## Documentation

- [Documentation index](docs/README.md) — **start here**: every page below, plus what each one answers.
- [Features](docs/FEATURES/README.md) — one page per area, each pointing into the decision record behind it.
- [Installation](docs/installation.md) — requirements, five package managers, what lib.nvim is used for.
- [Configuration](docs/configuration.md) — all five `setup()` keys and their defaults.
- [Command reference](docs/commands.md) — every command and argument, with the reasoning.
- [Bindings cheatsheet](docs/BINDINGS.md) — commands, autocommands and keymaps at a glance (there are no keymaps).
- [Lua API](docs/api.md) — what another plugin may call, and what is deliberately not API.
- [Workflow](docs/WORKFLOW.md) — not what each command reports, but which one answers which question.
- [`:help runtime-analysis`](doc/runtime-analysis.txt) — the same, inside the editor.

## License

MIT — see [LICENSE](LICENSE).
