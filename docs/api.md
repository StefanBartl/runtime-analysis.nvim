# Lua API

What another plugin, or your own config, may call directly. Everything not
listed here is internal and may be reshaped without notice — a command is the
stable surface for anything else.

## `require("runtime-analysis")`

```lua
---@param opts? table  see configuration.md
setup(opts)

---@param lines? string[]  buffer contents; default template when omitted
open_request(lines)
```

### `open_request` is the integration surface

`M.open_request(lines)` is this plugin's **one** public integration point,
written against a small named interface from the start — per
[`documentation.nvim/docs/ECOSYSTEM.md`](https://github.com/StefanBartl/documentation.nvim/blob/main/docs/ECOSYSTEM.md)
§7's own stated rule, rather than another plugin reaching into this one's
internal files.

documentation.nvim's `:DocBrowse` Endpoints mode is the first consumer:
pressing `gs` on a route it found by static analysis calls

```lua
require("runtime-analysis").open_request({ "METHOD path", "" })
```

as a **soft** dependency (`pcall(require, "runtime-analysis")`), absent with a
clear message when this plugin is not installed.

**Deliberately not an immediate send.** A route's path (`/users/:id`) is
relative and may contain unfilled `:param`s — genuinely nothing a static
analysis could send correctly on its own — so the method and path are
pre-filled and the reader completes the base URL (and any params) before
running `:RA send` themselves.

`:RA history` reuses the same call with the same shape, for the same reason: a
history entry *is*, by design, exactly that much information and no more.

## `require("runtime-analysis.startup")`

Stall detection. Narrative and options: [`FEATURES/STARTUP.md`](FEATURES/STARTUP.md).

```lua
local startup = require("runtime-analysis.startup")

startup.start({ duration_ms = 0 })  -- measure until told otherwise
startup.is_running()                --> boolean
startup.stop()                      -- stop measuring, keep what was collected
local lines, count, total_ms = startup.lines()
startup.report()                    -- stop, notify, write the log
startup.reset()                     -- drop everything collected
startup.probe_command()             --> the --cmd line, path filled in
```

`start(opts)` takes the table documented under
[Options](FEATURES/STARTUP.md#options) and **restarts** a run already in
progress rather than refusing — collected marks from the previous run are
dropped with it. `stop()` leaves them readable for a later `report()`.

## `require("runtime-analysis.loaded")`

The live `package.loaded` read documentation.nvim joins against its own static
IR. Narrative: [`FEATURES/LOADED.md`](FEATURES/LOADED.md).

```lua
local loaded = require("runtime-analysis.loaded")

loaded.functions(module_id)          --> table<string, true>? — keys, live
loaded.is_loaded(module_id)          --> boolean
loaded.snapshot(prefix, name?)       --> saved name, or nil
loaded.list_snapshots(prefix)        --> newest first
loaded.load_snapshot(prefix, name)
```

## `require("runtime-analysis.bench")`

Timed comparisons between candidate functions — deliberately **not** built on
telemetry's wrap/count machinery. Narrative:
[`FEATURES/BENCH.md`](FEATURES/BENCH.md).

```lua
local bench = require("runtime-analysis.bench")

local result = bench.compare(candidates, opts)
local lines  = bench.lines(result)
```

## `require("runtime-analysis.telemetry")`

The largest surface by far, and it has its own reference rather than a summary
here: **[`lua/runtime-analysis/telemetry/README.md`](../lua/runtime-analysis/telemetry/README.md)**
— instances, scoping (`wrap` / `wrap_loaded` / `wrap_fn`), per-key table
read/write counting, the lifecycle (`start` / `stop` / `unwrap`), persistence,
argument profiling, snapshots, reports and the HTML dashboard.

`telemetry.load(namespace)` is the one worth naming here: it reads a namespace
straight off disk, with no live instance and no editor session, which is what
makes [`scripts/telemetry.lua`](../scripts/telemetry.lua) possible.

## What is *not* API

- **Everything under `runtime-analysis.telemetry.renderers`.** Pick a
  `report_style` instead.
- **`runtime-analysis.parse`, `.runner`, `.view`, `.curl`, `.env`, `.history`,
  `.multipart`, `.graphql`, `.assertions`, `.inspect`, `.provenance`,
  `.usage`.** Real modules, documented in their own doc-comments and in
  [`commands.md`](commands.md), but shaped for the command that calls them.
- **`scripts/telemetry.lua`** is a headless CLI entry point, not a module to
  require.
