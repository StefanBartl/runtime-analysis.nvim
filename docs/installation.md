# Installation

Requirements, one spec per plugin manager, and what each dependency is
actually for. The README carries the lazy.nvim spec only — everything else
lives here.

## Requirements

| | |
| --- | --- |
| Neovim | **0.10+** — `vim.system` for the request runner, `vim.uv.hrtime` for telemetry timing |
| [lib.nvim](https://github.com/StefanBartl/lib.nvim) | required, hard dependency |
| `curl` on `PATH` | required for `:RA send` only — every other feature works without it |
| [mdview.nvim](https://github.com/StefanBartl/mdview.nvim) | optional, soft: renders a telemetry report as a live browser tab |
| [pdfport.nvim](https://github.com/StefanBartl/pdfport.nvim) | optional, soft: `.pdf` export of a telemetry report |

`:checkhealth runtime-analysis` verifies all of it on your own system.

## Package managers

### lazy.nvim

```lua
{
  "StefanBartl/runtime-analysis.nvim",
  lazy = false,  -- telemetry auto-instrumentation (opts.telemetry) needs to
                 -- be live before sibling plugins load, to catch their own
                 -- lazy-load moment. Request-runner-only usage works just as
                 -- well cmd-lazy-loaded instead:
                 -- cmd = { "RARequest", "RASend" },
  dependencies = { "StefanBartl/lib.nvim" },
  opts = {},
}
```

`lazy = false` is not a default carried over from a template. `opts.telemetry`
instruments a plugin at the moment it loads, through lazy.nvim's own
`User LazyLoad` event — a plugin that has already loaded before this one is
alive is only ever picked up by the slower catch-up scan. If you only want
the request runner, a `cmd` trigger costs nothing.

### vim.pack (Neovim 0.12+, built in)

```lua
vim.pack.add({
  { src = "https://github.com/StefanBartl/lib.nvim" },
  { src = "https://github.com/StefanBartl/runtime-analysis.nvim" },
})

require("runtime-analysis").setup({})
```

### mini.deps

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

### packer.nvim

```lua
use({
  "StefanBartl/runtime-analysis.nvim",
  requires = { "StefanBartl/lib.nvim" },
  config = function()
    require("runtime-analysis").setup({})
  end,
})
```

### paq-nvim / manual `rtp`

```lua
require("paq")({
  "StefanBartl/lib.nvim",
  "StefanBartl/runtime-analysis.nvim",
})

-- paq does no lazy-loading and runs no config hooks:
require("runtime-analysis").setup({})
```

## What lib.nvim is used for

Not a convenience import — this plugin is the reason several of these exist:

| Module | Used for |
| --- | --- |
| `net.curl` (`fetch_raw`, `fetch_raw_blocking`) | the request runner. This plugin is the reason both exist: the HTTP status code and the response headers were not exposed by that module at all before |
| `bindings.usercmd.composer` | `:RA` as one compound, `<Tab>`-completed verb |
| `progress` | the sending/cancel indicator, and telemetry's own reports |
| `fs.project_key` + `cache.disk` | per-project request history, and telemetry persistence |
| `fs.find_root` + `fs.json` | the environment files behind `:RA env` |
| `ui.kit` | every report float |
| `git`, `usercmd`, `notify`, `autocmd` | the ordinary plumbing |

## The `curl` dependency popup

`curl` is declared machine-readably in [`install.json`](install.json), parsed
by lib.nvim's
[`deps` module](https://github.com/StefanBartl/lib.nvim/blob/main/lua/lib/nvim/deps/README.md).
The first `setup()` after installing this plugin shows a one-time popup if it
is missing — and says that only `:RA send` needs it. `:Lib deps show
runtime-analysis.nvim` repeats it any time.

Three ways to turn it off, narrowest first:

```lua
require("runtime-analysis").setup({ deps_popup = false })   -- this plugin only
vim.g.lib_nvim_deps_disabled_plugins = { "runtime-analysis.nvim" }
vim.g.lib_nvim_deps_disable_first_run = true                -- every plugin
```

## Dev-only: the module map

[documentation.nvim](https://github.com/StefanBartl/documentation.nvim)
generates [`map/`](map/overview.md), this repository's own module map, adopted
per that project's
[`docs/REUSE.md`](https://github.com/StefanBartl/documentation.nvim/blob/main/docs/REUSE.md).
**It is not a runtime dependency** — nothing here needs it installed as a
plugin.

```sh
nvim --headless -l scripts/gen_map.lua           # regenerate
nvim --headless -l scripts/gen_map.lua --check   # verify, write nothing
```

`--check` is the CI gate (`.github/workflows/ci.yml`'s `map` job): it fails
loudly on a stale map rather than letting one rot on `main`.
`git config core.hooksPath scripts/hooks` installs the same check as a local
pre-commit hook.

This repository's map is published at
<https://stefanbartl.github.io/runtime-analysis.nvim/>;
[`map/overview.md`](map/overview.md) is the same tree as Markdown, rendered on
GitHub. History, Telemetry and Loaded need a local server and say so on the
published copy — every other tab works there in full.
