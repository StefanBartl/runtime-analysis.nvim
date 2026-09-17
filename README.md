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
live read of what is really in `package.loaded`, stall detection that finds
what blocks the main loop — including during startup, where `--startuptime` and
`:profile` both give up — and a startup profiler that runs `--startuptime`
enough times for its numbers to survive being read.

---

## Around it

> **[documentation.nvim](https://github.com/StefanBartl/documentation.nvim)** —
> it knows what exists and is documented; this plugin knows what actually
> happens when the code runs. The same project, from the two sides that can
> contradict each other — see [the join](docs/FEATURES/README.md#the-static--runtime-join).
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
> **[ui.nvim](https://github.com/StefanBartl/ui.nvim)** — reduces this
> plugin's telemetry to a single traffic light in the statusline: whether
> anything instrumented errored or ran slow today.
>
> All of the above are soft: without them everything else works unchanged.
> [lib.nvim](https://github.com/StefanBartl/lib.nvim) is the one real plugin
> dependency — see [Requirements](docs/installation.md#requirements).

---

## Documentation

Start at [docs/README.md](docs/README.md), which says what is where and which
question each page answers.

**The Basics**

- [Requirements](docs/installation.md#requirements) — Neovim version, required plugins and CLI tools.
- [Installation](docs/installation.md) — five package managers, what lib.nvim is used for.
- [Quickstart](docs/quickstart.md) — the first thing to run after installing.

**Configuration**

- [All options](docs/configuration.md) — all five `setup()` keys and their defaults.
- [Command reference](docs/commands.md) — every command and argument, with the reasoning.
- [Statusline](docs/statusline.md) — the one-glyph health light, for lualine, heirline, the native statusline or ui.nvim.
- [Bindings cheatsheet](docs/BINDINGS.md) — commands and autocommands at a glance. There are no keymaps.

**The Rest**

- [Features](docs/FEATURES/README.md) — one page per area: [requests](docs/FEATURES/REQUESTS.md), [telemetry](docs/FEATURES/TELEMETRY.md), [the loaded-module view](docs/FEATURES/LOADED.md), [stall detection](docs/FEATURES/STARTUP.md), [benchmarking](docs/FEATURES/BENCH.md), and [the static × runtime join](docs/FEATURES/README.md#the-static--runtime-join) with documentation.nvim and docmap-desktop.
- [Lua API](docs/api.md) — what another plugin may call, and what is deliberately not API.
- [Workflow](docs/WORKFLOW.md) — not what each command reports, but which one answers which question about a running session.
- [Feature log](docs/FEATURE_LOG.md) — the decision record: what shipped and the trade-off behind it.
- [Ideas](docs/IDEAS.md) — why an idea is cut the way it is, and what argues against it. Explicitly not a queue.
- [Contributing](docs/CONTRIBUTING.md) — ground rules, project layout, and how to add a command or an instrumentation.
- [Feedback](https://github.com/StefanBartl/runtime-analysis.nvim/issues) — bugs, feature requests and usage questions; broader discussion in [Discussions](https://github.com/StefanBartl/runtime-analysis.nvim/discussions).

`:help runtime-analysis` is the same reference inside the editor. There is no
troubleshooting page, on purpose: every symptom already has an address that
answers a different question about it — [docs/WORKFLOW.md](docs/WORKFLOW.md)
reads the common ones back to their cause, and `:checkhealth runtime-analysis`
covers the environment.

---

## License

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

runtime-analysis.nvim is released under the [MIT License](https://opensource.org/licenses/MIT).
