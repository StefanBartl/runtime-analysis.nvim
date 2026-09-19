# Statusline

`require("runtime-analysis.statusline").status()` reduces all instrumented
telemetry to one traffic light:

| | |
| --- | --- |
| 🔴 | something instrumented errored today |
| 🟡 | nothing errored, but something is running noticeably slow |
| 🟢 | everything instrumented looks fine |
| `""` | nothing has ever wrapped or started a telemetry instance |

It is a plain Lua string with no dependency on any statusline plugin, and
it degrades to `""` rather than erroring. A statusline is not the place for
a failure popup.

## Wiring it up

### lualine

```lua
require("lualine").setup({
  sections = { lualine_x = { require("runtime-analysis.statusline").lualine_component } },
})
```

`lualine_component` is `status` under another name — the alias exists so
the lualine spec reads the way lualine specs read.

### heirline, or anything else that takes a function

```lua
{ provider = function() return require("runtime-analysis.statusline").status() end }
```

### The native statusline

```vim
set statusline+=%{v:lua.require('runtime-analysis.statusline').status()}
```

### ui.nvim

Nothing to do. [ui.nvim](https://github.com/StefanBartl/ui.nvim) ships a
`runtime_analysis_ampel` segment that calls this module.

## What "slow" means

Above a lifetime mean call time of 50 ms. Pass your own threshold if that
does not match what you instrument:

```lua
require("runtime-analysis.statusline").status({ slow_mean_ms = 200 })
```

## Honest limits

**"Today", not "right now".** The light looks at `Data.days[today]` — the
functions actually called today — and reads their error count and mean call
time. Those two figures are *lifetime* totals, because telemetry aggregates
calls rather than timestamping each one.

Two consequences worth knowing before you trust the colour:

- A function that errored months ago and has not been called since will
  **not** turn this red. It has to be called again today to count.
- Once a function has errored at all, any day it is called again shows red,
  even if today's calls all succeeded.

That is the closest honest proxy for "currently" this data supports, and it
is deliberately not dressed up as more. For anything finer, `:RATelemetry`
shows the numbers themselves.

## Caching

The whole computed light — including which namespaces even exist — is
cached for 1 second, keyed by `slow_mean_ms`. A statusline redraws on
nearly every event, and even the "everything is live" path is not cheap:
finding out which namespaces exist scans the telemetry cache directory, and
folding a live instance's numbers into a colour does a full copy + re-merge
+ re-sort of everything it has collected. `M.invalidate()` drops this
cache, plus the disk-read cache below.

A namespace with no live instance is additionally read off disk, cached for
5 seconds on its own — a separate, longer-lived cache, since a namespace
with nothing live to report from still has to hit disk once the 1-second
cache above expires.

## Why this lives here

It used to live in ui.nvim: 140 lines reaching in through this plugin's
public facade to fold the numbers into a colour. The facade was the right
seam — it only ever used `get`, `load` and `known_namespaces`, never the
internal store — but the *interpretation* is this plugin's own opinion
about its own data: what counts as slow, what "today" means, which glyph.
That belonged here, with a test.

Two siblings — [sandbox.nvim](https://github.com/StefanBartl/sandbox.nvim)
and [sessions.nvim](https://github.com/StefanBartl/sessions.nvim) — already
shipped their own component, with ui.nvim reduced to a thin adapter over
it. This closes the same gap.
