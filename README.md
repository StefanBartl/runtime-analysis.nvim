> **Beta stage — active development.** This repository is past its first shape and in
> active use, but the surface is not frozen: breaking changes are still possible. Pin a
> commit or tag if you depend on it.

# runtime-analysis.nvim

```
╔═══════════════════════════════════════════════╗
║   r u n t i m e - a n a l y s i s . n v i m   ║
╚═══════════════════════════════════════════════╝
```

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Neovim](https://img.shields.io/badge/Neovim-0.10%2B-57A143?logo=neovim&logoColor=white)](https://neovim.io)
[![Lua](https://img.shields.io/badge/Lua-5.1%2FLuaJIT-2C2D72?logo=lua&logoColor=white)](https://www.lua.org)
![Status](https://img.shields.io/badge/status-beta-orange)
[![CI](https://github.com/StefanBartl/runtime-analysis.nvim/actions/workflows/ci.yml/badge.svg)](https://github.com/StefanBartl/runtime-analysis.nvim/actions/workflows/ci.yml)

Runtime truth for a Neovim project: what actually ran, not what the source says.

An in-editor HTTP request runner, opt-in call counting for any Lua plugin, a
live read of what is really in `package.loaded`, and stall detection that finds
what blocks the main loop — including during startup, where `--startuptime` and
`:profile` both give up.

---

## Table of contents

- [Documentation](#documentation)
- [What it does](#what-it-does)
- [Around it](#around-it)
- [Requirements](#requirements)
- [Installation](#installation)
- [Quickstart](#quickstart)
- [The static × runtime join](#the-static--runtime-join)
- [Health check](#health-check)
- [Contributing](#contributing)
- [Feedback](#feedback)
- [License](#license)

---

## Documentation

Start at [docs/README.md](docs/README.md), which says what is where and which
question each page answers.

- [Features](docs/FEATURES/README.md) — one page per area: [requests](docs/FEATURES/REQUESTS.md), [telemetry](docs/FEATURES/TELEMETRY.md), [the loaded-module view](docs/FEATURES/LOADED.md), [stall detection](docs/FEATURES/STARTUP.md), [benchmarking](docs/FEATURES/BENCH.md).
- [Installation](docs/installation.md) — requirements, five package managers, what lib.nvim is used for.
- [Configuration](docs/configuration.md) — all five `setup()` keys and their defaults.
- [Command reference](docs/commands.md) — every command and argument, with the reasoning.
- [Bindings cheatsheet](docs/BINDINGS.md) — commands and autocommands at a glance. There are no keymaps.
- [Lua API](docs/api.md) — what another plugin may call, and what is deliberately not API.
- [Workflow](docs/WORKFLOW.md) — not what each command reports, but which one answers which question about a running session.
- [Feature log](docs/FEATURE_LOG.md) — the decision record: what shipped and the trade-off behind it.
- [Ideas](docs/IDEAS.md) — why an idea is cut the way it is, and what argues against it. Explicitly not a queue.
- [Contributing](docs/CONTRIBUTING.md) — ground rules, project layout, and how to add a command or an instrumentation.

`:help runtime-analysis` is the same reference inside the editor.

There is no troubleshooting page, on purpose: every symptom already has an
address that answers a different question about it.
[docs/WORKFLOW.md](docs/WORKFLOW.md) reads the common ones back to their cause,
and `:checkhealth runtime-analysis` covers the environment.

---

## What it does

The through-line is one asymmetry. Static analysis can only see what is written
in the text: a function bound as a callback value, or reached through dynamic
dispatch, has no call site naming it — to a parser it does not exist, and the
telemetry sees it run. Everything here exists to be the counter-check to a
static analyzer, not a second one.

Four areas, one command surface: `:RA` runs something, `:RATelemetry` reports
on what has already run.

| Area | Does |
| --- | --- |
| **Requests** — [REQUESTS.md](docs/FEATURES/REQUESTS.md) | `.http` / `.rest` files, several requests per file, `{{var}}` environments split into a committed and a gitignored file, `curl` import and export, a `# @expect status 200` smoke-test directive, GraphQL and multipart bodies. No browser, no server, no CORS, no token — none of those problems exist for a request Neovim sends itself |
| **Telemetry** — [TELEMETRY.md](docs/FEATURES/TELEMETRY.md) | Opt-in call counting for any Lua plugin: which functions ran, how often, with what argument shapes, at what cost. A namespace can be read straight off disk with no live instance — including headless, for CI or a cron job |
| **Loaded** — [LOADED.md](docs/FEATURES/LOADED.md) | What `package.loaded` really contains right now, not what the source declares — plus named snapshots, so a process that never loaded the code can still read the answer |
| **Stalls** — [STARTUP.md](docs/FEATURES/STARTUP.md) | A libuv timer measuring its own lateness, so a block shows up whatever caused it: Lua, C, a subprocess, the OS. Plugin loads carry lazy's load time *and* the reason it loaded, which is usually what cracks the case |

Three more answer a question rather than run a job. `:RA inspect <module>`
walks a live module table — functions, upvalue counts, metatables, what a
direct key shadows through `__index`. `:RA provenance vim.notify` says who
wrapped a function: exact for this plugin's own wraps, honestly labelled as an
inference for anyone else's. `:RA usage` counts which of your own keymaps and
typed commands you actually press — the one feature here that records what the
*person* did rather than what the code did. And
[BENCH.md](docs/FEATURES/BENCH.md) times candidate functions against each
other.

Every command, argument by argument, is
[docs/commands.md](docs/commands.md).

---

## Around it

> **[documentation.nvim](https://github.com/StefanBartl/documentation.nvim)** —
> it knows what exists and is documented; this plugin knows what actually
> happens when the code runs. The same project, from the two sides that can
> contradict each other — see [the join](#the-static--runtime-join) below.
>
> **[insights.nvim](https://github.com/StefanBartl/insights.nvim)** — reads the
> source text for what looks unused: imports, symbols, metrics. This measures
> whether it was ever really called. A parser cannot see a callback, and a
> counter cannot see dead text.
>
> **[recommender.nvim](https://github.com/StefanBartl/recommender.nvim)** —
> where a suggestion about performance gets made; the benchmark that decides
> whether it is worth making belongs here.
>
> All of the above are soft: without them everything else works unchanged.
> [lib.nvim](https://github.com/StefanBartl/lib.nvim) is the one real plugin
> dependency — see [Requirements](#requirements).

---

## Requirements

| | |
| --- | --- |
| Neovim | **0.10+** |
| [lib.nvim](https://github.com/StefanBartl/lib.nvim) | required — the command layer and the shared helpers |
| `curl` | required for the request runner; everything else works without it |

`curl` is declared in [docs/install.json](docs/install.json) and read by
lib.nvim's
[deps module](https://github.com/StefanBartl/lib.nvim/blob/main/lua/lib/nvim/deps/README.md).
`:Lib deps show runtime-analysis.nvim` reports what is missing;
[docs/installation.md](docs/installation.md) says how to silence the one-time
popup.

---

## Installation

```lua
-- lazy.nvim
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

`lazy = false` is load-bearing for the telemetry: instrumentation that arrives
after the plugin it wants to measure has nothing to measure. If you only want
the request runner, the `cmd` variant in the comment is the better trade. Five
package managers are covered in
[docs/installation.md](docs/installation.md).

---

## Quickstart

Open a request buffer:

```vim
:RA request
```

One request per buffer, in the same shape VS Code's REST Client and IntelliJ's
HTTP Client already use:

```http
POST https://api.example.com/users
Content-Type: application/json
Authorization: Bearer abc123

{"name": "Alice"}
```

`:RA send` from inside it parses the buffer, sends it, and shows status,
headers and body in a split beside it — non-blocking, focus stays where you are
typing. That is the whole loop: edit, send, glance, edit again.

The other three areas answer rather than run:

```vim
:RA loaded                 " what package.loaded actually contains right now
:RA startup                " what blocked the main loop, and for how long
:RATelemetry               " what has run since instrumentation went live
:RA inspect <module>       " walk a live module table
:RA provenance vim.notify  " who wrapped this function
```

Verify your setup any time with:

```vim
:checkhealth runtime-analysis
```

---

## The static × runtime join

documentation.nvim's `:DocBrowse telemetry` mode joins this plugin's counts
against its static analysis; `:DocBrowse loaded` does the same for the
declared-against-loaded diff. Both read this plugin's data, never its
internals. The one *call* between the two plugins is `M.open_request`, which
`:DocBrowse` Endpoints uses to hand a route over as a request buffer: a small
named surface, a soft dependency, described in [docs/api.md](docs/api.md).

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

---

## Health check

```vim
:checkhealth runtime-analysis
```

Nine sections: the environment, lib.nvim, the telemetry state, the request
history, the environment files, the keymap and command usage log, the optional
tools, the registered commands, and the declared tools. The telemetry section
is the one to read when a count looks wrong — it says whether instrumentation
is live and which namespaces it is writing.

---

## Contributing

Clone the repository and either symlink it or add it to your runtime path.
[docs/CONTRIBUTING.md](docs/CONTRIBUTING.md) has the ground rules and the
project layout; [docs/FEATURE_LOG.md](docs/FEATURE_LOG.md) is the decision
record a new feature gets an entry in, and
[docs/IDEAS.md](docs/IDEAS.md) is where the arguments against one are already
written down.

Pull requests very welcome.

---

## Feedback

Your feedback is very welcome. Use the
[issue tracker](https://github.com/StefanBartl/runtime-analysis.nvim/issues) to
report bugs, suggest features or ask usage questions; anything more open-ended
fits a
[discussion](https://github.com/StefanBartl/runtime-analysis.nvim/discussions).

If you find this plugin useful, a ⭐ on GitHub supports its development.

---

## License

MIT — see [LICENSE](LICENSE).
