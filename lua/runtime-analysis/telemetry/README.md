# `runtime-analysis.telemetry`

Opt-in call counting and usage statistics. Answers *"how often was
`lib.strings.trim` called in the last 7 days, and with what arguments?"* — and,
when one argument dominates, says so and points at `lib.lua.memo`.

Counts survive restarts (`lib.nvim.cache.disk`, namespaced per plugin), which is
the whole point: the interesting question is asked days after collection
started.

```lua
local telemetry = require("runtime-analysis.telemetry")

local t = telemetry.new({ namespace = "lib.nvim" })
t.wrap(require("my.module"), "module")   -- or: t.wrap_loaded("my.plugin")
t.start()         -- counting only: the leave-it-on-for-a-week mode

-- days later
vim.print(t.report({ since = "7d", top = 20 }))
```

## Off costs nothing — literally

Instrumentation is **installed**, not compiled in. Until `start()` runs, the
shipped functions *are* the original functions — the same objects, not a
"nearly-free branch" — and `stop()` puts them back. That is why there is no
`if enabled then count() end` scattered through ~250 files, and why
`debug.sethook` (which fires on every Lua call in the process) was never an
option. Same pattern [`lib.nvim.system.proc_trace`](https://github.com/StefanBartl/lib.nvim/blob/main/lua/lib/nvim/system/README.md)
already uses for `vim.fn.system`.

When it *is* on:

| Mode | Per-call cost | Measured (200k calls, 2 scalar args) |
| --- | --- | ---: |
| Counting | one table index + one integer add | **~0.01 µs** |
| + timing | two `vim.uv.hrtime()` reads | ~0.2–0.4 µs |
| + argument profiling | one fingerprint computation | ~0.6–0.7 µs |
| + `call_tree` (docs/ROADMAP.md §3.1) | one `debug.getinfo(2, "Sl")` call | ~0.3–0.5 µs (counting + this) |
| `errors` / `outermost_only` | one `pcall` (the call must return through us even when it raises) | ~0.3 µs (the unconditional `pcall` tax alone, not counting a raise) |
| `errors`, on an actual raise | + one fingerprint of the error value (docs/ROADMAP.md §3.4) | — (only paid on the already-rare, already-`pcall`'d failure path; the success path above is unaffected) |
| `sample = N` (docs/ROADMAP.md §3.2) | the branches above run on only 1 in `N` calls; every other call takes the counting-only path | — (a caller controls the trade-off directly via `N`) |

**Ranges, not single numbers, and reproducible rather than quoted from
memory** — `scripts/bench_overhead.lua` (docs/ROADMAP.md §3.7's answer;
decision record in `docs/FINISHED.md`) is what actually measures this
table, run fresh for it rather than hand-typed. It is a plain repo script,
not a dev-only tool: **run it yourself** —
`nvim --headless -l scripts/bench_overhead.lua` — to get numbers for your
own machine instead of trusting either this table's or any other run's.
The table above is one real run's output, kept as a range because a second
run on the same machine already lands a little differently; treat any
single decimal here as false precision.

Counting is genuinely free at editor scale. Argument profiling is **~40–60×
counting** in every run measured so far — still nothing on a surface driven
by keypresses and autocmds (well under a microsecond × a few thousand calls
a day), and a real cost on helpers that run in inner loops. That asymmetry
is why it is opt-in per function rather than a global switch, and why
`profile_args` accepts a predicate:

```lua
t.start({ profile_args = function(key) return key:match("^bindings%.") ~= nil end })
```

**If you are turning on more than counting, know what it costs on your own
setup before leaving it on.** Counting alone is safe to leave running
indefinitely — that is this module's whole premise (see "Zero-cost when
stopped" above and docs/ROADMAP.md §3.5). Argument profiling, `call_tree`
and `errors` are each real, measured multiples of that floor, not
rounding error — on a function called heavily enough, stacking several of
them is the kind of cost you want a number for, not an assurance, before
deciding whether to leave it enabled between sessions or turn it on only
while you are actually looking at something. `scripts/bench_overhead.lua`
exists so that number is a five-second measurement on your machine, not a
guess from this table.

### Call trees — "who called this" (docs/ROADMAP.md §3.1)

A flat count answers "`fs.read` was called 4 812 times"; it cannot answer
the question that usually follows, "by whom". `call_tree` records the
immediate caller — one frame of `debug.getinfo(2, "Sl")`, source file +
line — as a bounded-cardinality bucket, the identical shape and identical
`max_arg_values` bound `profile_args` already uses for arguments:

```lua
t.wrap(mod, "fs", { call_tree = true })
-- or, opt-in per key at start() time, same predicate/list/true shapes
-- profile_args already accepts:
t.start({ call_tree = function(key) return key == "fs.read" end })
```

```
fs.read  —  4 812 calls
    ← 61 %  lua/lib/nvim/fs/init.lua:42
    ← 23 %  lua/documentation/core/scan.lua:118
    ← 16 %  <other: 9 distinct>
```

**Source + line, not a resolved caller name.** `debug.getinfo(2, "Sln")`
(name resolution added) measured ~0.51 µs against `"Sl"`'s ~0.32 µs —
`~60 %` more expensive for information a call site's own source location
already narrows down unambiguously, and it is the identical join key
`documentation.nvim`'s own static `calls` extraction already uses (a call
edge's line number, not a resolved caller name) — see `docs/ECOSYSTEM.md`
step 8 for that join in practice. `sample = N` applies to `call_tree`
exactly as it already does to `profile_args`/`time`/`errors`: only every
Nth call pays for the `debug.getinfo` lookup, `calls` itself stays exact
regardless.

## API

### `telemetry.new(opts)` → instance

Instance-based, not a singleton — same shape as `logger.new()`, and for the same
reason: any plugin must be able to point one at its own surface with its own
persisted counts.

| Option | Default | Meaning |
| --- | --- | --- |
| `namespace` | `"unnamed"` | required in practice; also the on-disk cache key |
| `dir` | `stdpath("cache")/runtime-analysis.nvim/cache` | cache directory override |
| `retention_days` | `30` | day buckets older than this are pruned on flush |
| `flush_interval_ms` | `60000` | debounced periodic flush; `0` disables |
| `remind_after` | `{ days = 7, calls = 50000 }` | lifecycle reminder; `false` opts out |
| `persist` | `true` | `false` keeps everything in memory |
| `max_arg_values` | `32` | distinct fingerprints kept per function |
| `report_file` | `false` | keep this namespace's Markdown report on disk, rewritten at every flush — see "Browser report" |
| `info` | `{}` | free-form metadata bundled with the report (branch, version, …) — see "Report metadata" below |

A second `new()` with a namespace that already has a live instance **warns** —
two plugins sharing a namespace would silently merge into one cache file and
produce wrong numbers, and that failure is otherwise invisible.

### Scope — whole table, some functions, or one function

Instrumenting everything is rarely what you want and is the version with the
highest on-cost. Scope narrows at four granularities:

```lua
t.wrap(require("lsp.servers"), "servers")                                  -- a whole module
t.wrap(require("lsp.servers"), "servers", { only = { "attach", "detach" } })
t.wrap(require("lsp.handlers"), "handlers", { except = { "on_publish" } })
t.wrap(require("lsp.util"), "util", {                                      -- a predicate
  filter = function(name) return not name:match("^_") end,
})

local traced = t.wrap_fn(factory().find, "find_root.find")                 -- a bare function
```

`only` / `except` take **exact names**, never patterns; `filter` is the single
escape hatch, rather than two overlapping mechanisms each needing their own
edge cases explained.

`wrap_fn` exists because some interesting functions are not reachable as a named
table field (a closure returned by a factory, a callback held in a local). It
returns a stable dispatcher you must store and call in place of the original —
that indirection is what lets `start()`/`stop()` toggle instrumentation without
your saved reference going stale.

Instrumenting lib.nvim's own `require("lib")` aggregate specifically is not
this module's job — that aggregate's key set is metatable-hidden and only
resolvable via lib.nvim's own `lib.strategies.control` strategy, so lib.nvim
ships a thin caller, `lib.strategies.telemetry_wrap`, built entirely on the
public `wrap()` above (materialize the hidden keys via `rawset`, then
`inst.wrap(lib)`). Anything else — a plain table, a plugin's own modules —
wraps directly with `wrap()`/`wrap_loaded()`.

### `wrap_loaded` — a whole plugin, not just its façade

Wrapping one module usually measures the wrong thing. A plugin's `init.lua`
is typically a thin façade over the modules that hold the real code —
`require("markdown")` exposes **11** one-line delegators while the 35 loaded
`markdown.*` modules hold **125** functions, and the ones its keymaps actually
call live only in the latter.

```lua
t.wrap_loaded("markdown")                       -- the whole loaded subtree
t.wrap_loaded("markdown", {
  module_only   = { "markdown.bindings.actions" },   -- exact module names
  module_except = { "markdown.config" },
  module_filter = function(name)                     -- predicate over the path
    return not name:find("@types", 1, true)
  end,
  only = { "attach" },                               -- per-function scoping
})                                                   -- still applies underneath
```

Module-level scoping uses the same `only`/`except`/`filter` vocabulary as the
per-function scoping, one level up, so there is one thing to learn rather than
two. Both apply: modules are selected first, then functions within them.

Keys are the module path minus the prefix, plus the function name —
`markdown.bindings.actions.next_heading` → `bindings.actions.next_heading`.
The namespace already says which plugin this is.

**Why "loaded" and not "every module on disk":** discovering submodules by
scanning `lua/` would mean `require`-ing every file to see what is in it,
forcing eager loading of modules the plugin deliberately deferred and running
their top-level code as a side effect of counting. Reading `package.loaded`
costs nothing and cannot break a lazy-loading plugin. The trade-off is that
coverage is *"what is loaded at this moment"* — call it after the plugin has
initialized, and call it again later to pick up modules required since
(re-registering an existing target is a no-op, so nothing double-counts).

### `telemetry.auto(opts)` — instrument a plugin on load, any plugin manager

`new()` + `wrap()`/`wrap_loaded()` + `start()` in one call — the shape every
"auto-instrument each plugin as it loads" caller needs, regardless of which
plugin manager drives it:

```lua
-- from inside a lazy.nvim `User LazyLoad` callback, packer's `config`, or
-- anywhere else that knows a plugin just finished loading:
local inst = telemetry.auto({
  namespace = "markdown.nvim",
  main = "markdown",          -- the plugin's root Lua module
  deep = true,                -- wrap_loaded(main) instead of just its façade
  profile_args = true,
  timing = false,
  -- persist / dir forward straight to new() -- real callers rarely need
  -- either (persist defaults to true), but a test suite calling auto()
  -- repeatedly against the real stdpath("cache") does: pass persist = false
  -- or an isolated dir, the same as any other instance.
})
-- inst is nil if nothing of `main` is loaded yet -- no empty namespace left
-- behind, and safe to call on every load event without your own dedup guard
-- around the *creation*, though you still want one around firing this call
-- itself: calling it twice for an already-instrumented plugin creates a
-- SECOND live instance for the same namespace (see "Persistence is
-- namespaced" below) -- exactly the kind of dedup a `User LazyLoad` handler
-- already needs on its own for other reasons.
```

What this deliberately does **not** do: hook a load event, or resolve `main`
from a plugin spec. Both are plugin-manager-specific (lazy.nvim's own
`lazy.core.loader.get_main`, for one) — a generic library has no business
assuming which one you use. Deciding *which* of your plugins get *which*
settings is your own policy too; `auto()` only takes the settings already
resolved for one plugin, not a list to resolve them from.

By default, `deep = true`'s `module_filter` excludes `@types` modules —
pure LuaCATS annotation scaffolding, noise in every report — overridable by
passing your own `module_filter`.

### `telemetry.lazy` — the lazy.nvim adapter

`auto()` still leaves hooking a load event and resolving a plugin's Lua
module to you. If lazy.nvim is your plugin manager, this module does both:

```lua
require("runtime-analysis.telemetry.lazy").setup({
  plugins = {
    -- keyed by repo, as declared in the lazy.nvim spec's first element
    ["StefanBartl/markdown.nvim"] = { namespace = "markdown.nvim", deep = true, profile_args = true },
    ["StefanBartl/lib.nvim"] = nil, -- see lib_nvim below instead
  },
  lib_nvim = { profile_args = false }, -- false/omit to skip entirely
})
```

Wire it from `runtime-analysis.nvim`'s own plugin spec, not a separate
config file or a call before `lazy.setup()`:

```lua
{
  "StefanBartl/runtime-analysis.nvim",
  lazy = false,
  dependencies = { "StefanBartl/lib.nvim" },
  opts = { telemetry = { plugins = {...}, lib_nvim = {...} } },
  config = function(_, opts) require("runtime-analysis").setup(opts) end,
},
```

**Catch-up, not just the event.** `User LazyLoad` fires the moment a
plugin's own `config()` finishes — for a `lazy=false` *dependency* of this
plugin (`lib.nvim`, typically), that happens **during** `lazy.setup()`,
quite possibly before this plugin's own `config()` (the only place `setup()`
above could realistically run from) ever executes. Registering only the
autocmd would silently miss it. `setup()` instead scans everything already
loaded the moment it runs, wraps what's already there, then registers the
autocmd for everything after — no "must run before `lazy.setup()`" ordering
requirement, unlike hooking `User LazyLoad` directly yourself.

**`lib_nvim` is separate from `plugins`** because instrumenting
`require("lib")`'s own aggregate goes through lib.nvim's own
`lib.strategies.telemetry_wrap` (metatable-hidden keys; `wrap_loaded("lib")`
would also reach every internal helper in a large library, when the
interesting question is which of its *public* keys get used), not
`auto()`. Soft dependency either way: if lazy.nvim is not your plugin
manager, or lib.nvim's `telemetry_wrap` is not reachable, `setup()` and the
`lib_nvim` option are simply no-ops, not errors.

**No other plugin manager is supported.** packer.nvim has no per-plugin
load event to hook (and is no longer actively maintained); vim-plug has no
lazy-loading concept at all. Detecting which manager is active is easy;
writing and maintaining an adapter for ones nobody here uses is not worth
the surface. Use `auto()` directly if you need this on something else.

### `telemetry.setup_all` — bulk backup + reset + re-wrap + restart

`M.setup()`'s catch-up scan wraps a plugin's loaded modules exactly once —
either right away (already loaded when `setup()` ran) or on its own `User
LazyLoad`. A submodule that plugin `require`s *later* (a command handler
pulled in on first use, a UI module loaded on first keypress) is never
retroactively wrapped: not because `profile_args` is off, but because
nothing ever installed a wrapper around it at all. `:RATelemetrySetupAll` /
`:RATelemetrySetupAllFull` exist to re-scan, so a function that has been
silently invisible all session joins the wrap the next time either runs.

```lua
local lazy = require("runtime-analysis.telemetry.lazy")
lazy.candidates()
-- {
--   { repo = "StefanBartl/markdown.nvim", namespace = "markdown.nvim",
--     main = "markdown", settings = { namespace = "markdown.nvim", deep = true, profile_args = true } },
--   ...
-- }

require("runtime-analysis.telemetry.setup_all").run({
  full = false,            -- true forces profile_args + timing for every candidate
  backup_dir = nil,        -- set to write a pre-reset JSON backup per namespace that has data
  on_done = function(results) ... end,
})
```

`lazy.candidates()` resolves every `opts.telemetry.plugins` entry (the same
policy table `M.setup()` above received — stored, not re-derived, so a
caller of `setup_all` never has to pass the list a second time) that lazy.nvim
can currently point at a *loaded* root module — everything `setup_all.run()`
needs to act on without re-deriving lazy.nvim's own plugin table itself.
`lib_nvim` is never a candidate: it wraps through
`lib.strategies.telemetry_wrap`, not `wrap_loaded()`, so the generic re-scan
step here does not apply to it.

For each candidate, `setup_all.run()`: flushes a live instance if one
exists (so a backup reflects calls not yet on disk), backs it up to
`backup_dir` when given and there is anything to back up, `reset()`s it,
re-wraps (`wrap_loaded()` if `settings.deep` or `run_opts.full`, else the
façade-only `wrap()` — same rule `auto()` itself uses), then `start()`s it
with either the plugin's own configured `profile_args`/`timing`
(`run_opts.full = false`) or both forced on (`run_opts.full = true`).

`:RATelemetrySetupAll`/`:RATelemetrySetupAllFull` (`docs/COMMANDS.md`) are
the UI over this: one `vim.ui.input()` prompt for the whole run — never one
per plugin — asks where to back up, and only appears when at least one
candidate actually has data to lose.

### Lifecycle

```lua
t.start()                                  -- counting only
t.start({ profile_args = { "fs.find_root" },  -- a key list,
          time = true,                        -- `true` for everything,
          errors = function(key)              -- or a predicate over the key
            return key:match("^io%.") ~= nil
          end })
t.stop()                                   -- restores originals, keeps the data
t.is_running()
t.unwrap()                                 -- also forget the registered targets
```

`stop()` is idempotent — a second `stop()`, or one on an instance that never
started, is a no-op rather than an error, because hot-reloaded configs call
setup paths repeatedly.

### Persistent enable/disable

`stop()` only affects the current process — tomorrow's session calls
`t.start()` again and it's back. For "I looked at `markdown.nvim`'s numbers,
I'm done, stop wrapping it, and don't start it again next time either" without
editing whoever calls `t.start()` at startup:

```lua
telemetry.disable("markdown.nvim")   -- persists; stops a live instance right now
telemetry.enable("markdown.nvim")    -- clears it; resumes a live instance right now
telemetry.is_disabled("markdown.nvim")
telemetry.disabled()                 -- every namespace currently disabled
```

Or from the command line: `:RATelemetry disable markdown.nvim` /
`:RATelemetry enable markdown.nvim` / `:RATelemetry disabled`. Works even
before that namespace's instance has ever been created (disable a plugin
before it loads this session) — `inst.start()` checks the flag and is a
no-op while it's set, so the caller that wires `t.start()` up once at startup
never has to change. The flag lives in its own cache entry, separate from a
namespace's collected data, so `t.reset()` clears counts without silently
re-enabling anything.

One documented edge: the flag is persisted under the instance's own
`opts.dir` once that instance exists (so it's checked consistently), but
falls back to the default cache dir when disabling a namespace that has no
live instance yet. If that instance later shows up with a **custom** `dir`,
disable it again after it's created rather than before.

### Reading the data

```lua
t.report({ sort = "calls", top = 30, since = "7d" })  -- table
t.lines({ top = 20 })                                 -- rendered strings
t.coverage()                                          -- { called, uncalled }
t.resolved_modules()                                  -- { [key] = real Lua module path }
t.reset()                                             -- clear memory + disk
t.flush()                                             -- persist now
```

`sort` is `"calls"` (default), `"name"` or `"time"`. `since` accepts `"7d"`,
`"24h"`, `"2w"` or a bare day count and is answered from the per-day buckets.

`coverage()` is the inverse question: which registered functions were called
**zero** times. An exported, documented, never-used function is a maintenance
cost.

Module level:

```lua
telemetry.instances()        -- every live instance
telemetry.get("lsp.nvim")
telemetry.report_all(opts)
telemetry.start_all()        -- also `:RATelemetry start` (bare)
telemetry.flush_all()
telemetry.stop_all()         -- also `:RATelemetry stop` (bare)
```

### Report metadata — which branch/version this data came from

A count on its own does not say *when* it is from — 12,000 calls to a
function that no longer exists by that name a week later is a stale number
wearing a fresh-looking one's clothes. `Options.info` bundles whatever the
caller considers the important context alongside the counts:

```lua
telemetry.new({
  namespace = "lsp.nvim",
  info = { branch = "main", version = "v1.2.3" },  -- any string keys, any string values
})
```

This module never inspects a repo to guess at that — the caller almost
always already knows which directory its own plugin lives in, and guessing
wrong silently is worse than not having the field. `lib.nvim.git.info(dir)`
is a ready-made source for the common case:

```lua
local info = require("lib.nvim.git").info(plugin_dir)
-- { branch = "main", version = "v1.2.3" or a short hash if untagged, commit = "abc1234" }
telemetry.new({ namespace = "lsp.nvim", info = info })
```

Shows up in `t.report().info`, and as a line in both `t.lines()` and
`t.markdown()` (sorted by key, so rendering is deterministic) — absent
entirely when empty, rather than an empty line nobody asked for.

**Last-write-wins, not merged field-by-field.** A branch switch between
sessions replaces the whole `info` table on the next flush; the previous
session's fields do not linger alongside the new ones the way `wrap_loaded()`
keys or counts accumulate. `Options.info` is set once at construction
(`telemetry.new`) — there is no `t.set_info(...)` to change it mid-process,
the same way `dir`/`persist` are construction-time only.

### Reading without an instance — and resolving keys to real modules

A fresh Neovim process with no live instance for a namespace (a `:DocMap
check` run, a CLI tool, a health check) can still read what an *earlier*
session collected:

```lua
local data = telemetry.load("lsp.nvim")   -- RA.Telemetry.Data|nil
if data then
  vim.print(data.functions)   -- same shape as t.report() works from
end
```

`nil` means *nothing was ever persisted for this namespace* — deliberately
distinct from a well-formed empty table. A caller has to be able to tell
"telemetry was never enabled here" from "enabled, and zero calls happened",
or an unanalyzed tree renders as a graveyard instead of "no data".

The other half of "read this from outside the process that collected it" is
matching a telemetry key back to the real Lua module it came from — the key
alone (`"bindings.actions.next_heading"`) does not say that. `wrap_loaded()`
knows the answer at wrap time (its keys ARE derived from a real
`package.loaded` path) and records it automatically:

```lua
t.wrap_loaded("markdown")
t.resolved_modules()   -- { ["bindings.actions.next_heading"] = "markdown.bindings.actions", ... }
```

The same map is in `data.modules` from `telemetry.load()`, keyed the same
way — no live instance required to read it either. A plain `t.wrap(container,
prefix)` resolves nothing on its own (`prefix` is a caller-chosen label, not
necessarily a real module path — `t.wrap(require("lsp.servers"), "servers")`
does not make `"servers"` mean `"lsp.servers"`), unless the caller vouches
for it explicitly:

```lua
t.wrap(require("lsp.servers"), "servers", { module_id = "lsp.servers" })
```

A key with no entry in `resolved_modules()` / `data.modules` is **unmatched**,
not "zero calls" — a consumer joining telemetry against a static key set (the
motivating case: documentation.nvim's `dead-function` check, see
[`telemetry-documentation-bridge.md`](https://github.com/StefanBartl/lib.nvim/blob/main/docs/ROADMAP/telemetry-documentation-bridge.md))
must keep those two claims distinguishable, or the join produces false
positives it can't tell apart from real ones. That design document stayed in
lib.nvim when this module moved out of it — it is about the *consumer* of
this data, not about the collection this module does, so it was never
telemetry's own file to take along.

### Named snapshots — docs/ROADMAP.md §4.5

`telemetry.load()`/`t.report()` above are always the *current* aggregate —
one continuously-overwritten slot per namespace. There is no way to ask
"what did this look like last Tuesday" once today's counts have merged in.
A snapshot is a second, independent capture, saved under a name and never
merged into again:

```lua
telemetry.snapshot("lsp.nvim")              -- name defaults to a timestamp
telemetry.snapshot("lsp.nvim", "pre-refactor")

telemetry.list_snapshots("lsp.nvim")
-- { { name = "pre-refactor", saved_at = 1723300000 }, { name = "2026-08-10T14-02-11", saved_at = 1723299000 } }

local before = telemetry.load_snapshot("lsp.nvim", "pre-refactor")
-- RA.Telemetry.Data|nil, same shape telemetry.load() returns
```

If a live instance exists for the namespace, `telemetry.snapshot()` flushes
it first — the capture has to reflect calls already collected but not yet
on disk, or "snapshot now" would sometimes mean "as of the last periodic
flush" depending on timing. With no live instance, whatever is already on
disk (the aggregate from the last flush, by any process sharing the
namespace) is captured as is — reading, not requiring, a live instance,
the same posture `telemetry.load()` itself takes.

**Always explicit, on purpose.** Nothing in this module ever calls
`telemetry.snapshot()` on its own — no auto-snapshot on `disable()`, on a
flush, on an interval. An unexpected snapshot silently evicting a
namespace's older, possibly still-wanted ones was judged a worse failure
mode than a missed one. The only call site is `:RATelemetry snapshot`:

```
:RATelemetry snapshot lsp.nvim              " auto-named (a timestamp)
:RATelemetry snapshot lsp.nvim pre-refactor
:RATelemetry snapshots lsp.nvim             " list, newest first
```

**Which machine took a snapshot.** `telemetry.snapshot()`'s third argument
tags the capture with a device — the case this exists for: read data,
change something, read data again — possibly on a different machine —
compare. Defaults to `vim.uv.os_gethostname()`, shown wherever `Data.info`
already renders (no new rendering code):

```lua
telemetry.snapshot("lsp.nvim", "pre-refactor")                       -- device: this machine's hostname
telemetry.snapshot("lsp.nvim", "pre-refactor", { device = "laptop" }) -- explicit override
telemetry.snapshot("lsp.nvim", "pre-refactor", { device = false })    -- no device tag at all
```

**Comparing two snapshots.** `telemetry.compare()` (above) reads one
continuously-accumulating dataset's own day buckets — "this week vs last
week." Two named snapshots are a different question: independent captures,
arbitrarily far apart, `Data.functions[key].calls` a lifetime total in
each. `telemetry.compare_snapshots()` diffs them directly, classifying by
the A→B *delta* rather than raw totals (a lifetime counter only grows, so
"silent since the beginning" can never fire between two ordered snapshots —
"no new calls in this period" is the question that actually has an answer):

```lua
local cmp = telemetry.compare_snapshots("lsp.nvim", "pre-refactor", "post-refactor")
-- RA.Telemetry.SnapshotComparison|nil -- nil when either name was never saved
vim.print(require("runtime-analysis.telemetry.report").compare_snapshots_lines(cmp))
```

```
:RATelemetry snapshot-compare lsp.nvim pre-refactor post-refactor
```

**Retention** is LRU — `telemetry.SNAPSHOT_RETENTION` (default `20`), an
oldest-evicted cap applied after every `telemetry.snapshot()` call, so a
namespace snapshotted often never accumulates an unbounded set. `keep <= 0`
means "do not evict," never "delete everything," so an unset or zero
config value can't wipe a namespace's history by accident. Override it
per namespace with `opts.snapshot_retention` on `telemetry.new()`:

```lua
local t = telemetry.new({ namespace = "lsp.nvim", snapshot_retention = 50 })
```

— which wins over the global default for that namespace specifically;
`telemetry.SNAPSHOT_RETENTION` itself still applies to a namespace read via
`telemetry.snapshot()`/`load_snapshot()` with no live instance (a fresh
process, a CI run), which has no per-instance override to carry.

## `:RATelemetry`

Opt-in, like `:LibLogger` — requiring the module registers nothing:

```lua
require("runtime-analysis.telemetry.command").setup()
```

```vim
:RATelemetry                 " report across every live instance, in a kit float
:RATelemetry lsp.nvim        " report for one namespace
:RATelemetry start [ns]      " every instance, or just one
:RATelemetry stop [ns]       " every instance, or just one
:RATelemetry reset [ns]      " every instance, or just one
:RATelemetry coverage
:RATelemetry export [path]   " JSON; Markdown if .md; PDF if .pdf (needs pdfport.nvim)
:RATelemetry export-all <dir>  " one Markdown file per namespace found ON DISK into <dir>
:RATelemetry open [ns]       " render + open externally — see "Browser report" below
:RATelemetry compare [ns] [days]   " "this week vs last week" — see below
:RATelemetry startup [top]   " which module a plugin's startup cost sits in
:RATelemetry cost            " startup cost vs. call count, worst first

:RATelemetryStartAll         " same as :RATelemetry start (bare) -- a standalone alias
:RATelemetryStopAll          " same as :RATelemetry stop (bare) -- reached for often enough to earn its own name
```

`start`/`stop`/`reset`/`open`/`compare` take an optional namespace —
`:RATelemetry stop markdown.nvim` steers just that instance, leaving every
other one running. Omit it to act on every instance at once. `<Tab>` after
`start `/`stop `/`reset `/`open `/`compare ` completes namespaces only
(not the subcommand list again). `compare`'s own third, purely positional
token overrides the default 7-day window — `:RATelemetry compare
markdown.nvim 14`.

`export`'s format is inferred from the target path's own extension rather
than a separate flag — this command's argument parsing stays positional
throughout. `:RATelemetry export report.md` writes the same document
`telemetry.markdown_all()` would; `:RATelemetry export report.pdf` hands
that exact document to [pdfport.nvim](https://github.com/StefanBartl/pdfport.nvim)
(optional dependency, `pcall`-guarded — needs pandoc + a PDF engine,
`pdfport.can_create("markdown")`) as text instead of writing a `.md` file
first; anything else (including the default auto-named path) writes the
existing JSON snapshot.

`scripts/telemetry.lua export <namespace> <path>` (the headless/CI entry
point) follows the identical extension rule, and finds pdfport.nvim on the
runtimepath the same way it finds lib.nvim — `PDFPORT_DIR`, a
`.deps/pdfport.nvim` checkout, or a sibling checkout beside this repo — but
best-effort: only `export ... .pdf` needs it, everything else works without.

`export-all` is the one command in this list that is not scoped to
`instances` (this process's live ones). `export`/`report_all`/`markdown_all`
all read only what THIS Neovim process has instrumented THIS session — a
plugin nothing has loaded yet, or one instrumented in a process that has
since exited, is invisible to them. `export-all` instead scans
`stdpath("cache")/runtime-analysis.nvim/cache/telemetry/*.json` directly
(`store.namespaces()`) and builds each namespace's report straight from
what is on disk (`telemetry.load()` + `report.build()`, no live instance
required), one `<namespace>.md` file per namespace into the given
directory — the way to get every instrumented plugin's report in one
command without first loading all of them in the same session.

```lua
local written, failed = telemetry.export_all("~/telemetry-export")
```

## Browser report

Two separable things: rendering a report as **Markdown** (useful on its own —
paste into an issue, commit a snapshot, diff two weeks), and handing that
Markdown to a **browser** via [mdview.nvim](https://github.com/StefanBartl/mdview.nvim)'s
own `:MDView standalone`, which already does exactly the right thing for
this: it hands a file path to the relay binary's own `--watch` mode and steps
out of the chain entirely — the relay watches the file on disk and
broadcasts changes to the browser itself. mdview.nvim is a soft dependency
throughout, `pcall`-guarded.

```lua
t.markdown({ since = "7d", top = 30 })   -- -> string[], the same shape as t.lines() but GFM
telemetry.markdown_all(opts)             -- every instance, one combined document
```

**Self-updating, opt-in:** `report_file = true` keeps a namespace's Markdown
report on disk (`stdpath("cache")/runtime-analysis.nvim/telemetry/<namespace>.md`),
rewritten at every flush. Point `:MDView standalone` at that same path (or
just use `:RATelemetry open <ns>`) and the browser tab becomes a live
dashboard with no new machinery on either side — telemetry already flushes
periodically, mdview's relay already watches a file. Writing a Markdown file
every 60 s for someone who never opened a browser is waste, so this is opt-in
per instance:

```lua
telemetry.new({ namespace = "lib.nvim", report_file = true })
```

**`:RATelemetry open [ns]`** renders + opens externally, forcing a flush
first so the render is current. Which renderer it uses is configuration, not
a subcommand — the same shape `lib.nvim.progress` already uses for its
`progress_style`:

```lua
require("runtime-analysis.telemetry").setup({
  report_style = "auto",   -- "auto" | "kit" | "mdview" | "file" | "html"
})
```

| Style | Effect |
| --- | --- |
| `"auto"` (default) | mdview if loadable, else the kit float |
| `"kit"` | the same in-editor float `:RATelemetry <ns>` already renders |
| `"mdview"` | write the report + `:MDView standalone` it; falls back to `"kit"` if mdview is not loadable |
| `"file"` | just write the report to disk, no window opened |
| `"html"` | render the sortable/filterable HTML dashboard (docs/ROADMAP.md §4.4, below) and open it in the system browser |

This is module-level, not per-instance (`telemetry.setup`, not
`telemetry.new({...})`) — `:RATelemetry open` with no namespace spans every
live instance at once, so there is one resolved answer to "how should `open`
render", not one per instance.

Honest limits:

- **The browser shows the last flush, not this instant.** `open` forces one,
  so the initial render is current; after that it is as live as
  `flush_interval_ms`.
- **A bare `:RATelemetry open` (no namespace) is a snapshot, not
  self-updating.** Only a per-namespace file has one flush cycle that owns
  it; the combined `report.md` has no single instance to keep rewriting it,
  so it is rendered fresh at invocation time and left there.
- **HTML exists now, but as its own explicit style, not folded into
  `"auto"`.** §4.4 shipped a small, purpose-built dashboard
  (`renderers/html.lua`) rather than duplicating mdview's Markdown
  rendering — see "HTML dashboard" below for what it is and, just as
  importantly, what it deliberately is not. `"auto"` still means
  mdview-or-kit, unchanged: opening a whole browser tab is a bigger
  action than a config default should take silently.
- **mdview.nvim self-installs its relay binary from GitHub Releases on first
  use** (checksum-verified, no Go/Rust toolchain needed) — for *either* of
  its modes, not just standalone. The first `:RATelemetry open` with
  `report_style = "mdview"` may pause briefly for that download; failures
  (no network, no `curl`) are mdview's own to report, and this bridge just
  degrades to `"kit"`.

## HTML dashboard (docs/ROADMAP.md §4.4)

`report_style = "html"` renders a self-contained HTML page — one flat
table, one row per (namespace, function): calls, errors, mean timing
(when `timing` is on), the single most-called argument fingerprint and
its share, the single most-common immediate caller and its share.
Click a row for the full breakdown — every kept fingerprint, the
memoization hint, error fingerprints, callers — the same `└`/`✗`/`←`/`ⓘ`
symbols the terminal report already uses. Sortable by clicking a column
header; filterable by a plain substring over namespace + function key.

```vim
:RATelemetry open           " combined dashboard, every live instance
:RATelemetry open lib.nvim  " one namespace's own dashboard
```

or via config:

```lua
require("runtime-analysis.telemetry").setup({ report_style = "html" })
```

Written to `stdpath("cache")/runtime-analysis.nvim/telemetry/<namespace>.html`
(or `report.html` for the combined, no-namespace case) and opened with
`lib.nvim.fs.open.url.system_opener` — the same cross-platform "hand this
to the OS" mechanism `:DocMap open` already uses.

**Deliberately not documentation.nvim's own renderer, reused wholesale.**
That module's `core/render/html.lua` is roughly 4,500 lines, of which
roughly 3,850 are one embedded JavaScript single-page application
tightly coupled to its own IR (module nodes, require/call edges,
findings) — genuinely reusing it for telemetry's own, completely
different data shape would mean either a real extraction project in that
repository first, or bolting foreign data onto machinery built for a
tree, neither of which is "worth doing only if the Markdown report is
actually being read often enough to feel limiting" (§4.4's own stated
precondition) actually asks for. Decided 2026-08-04: reuse the *design*
— the same CSS custom properties (colors, spacing, light/dark via
`prefers-color-scheme` and `data-theme`), the same visual language
(badges, section labels, the toolbar search input) — in a new, small,
self-contained page written for this data, not that one.
[`renderers/html.lua`](renderers/html.lua)'s own doc-comment has the full
reasoning.

**Client-side data handling, stated plainly because it matters:** every
row's data is embedded as a JSON blob in a `<script>` tag and rendered
by a small (~250-line) vanilla-JS table — no framework, no CDN, nothing
fetched over the network. Two escaping passes exist for two different
reasons: the JSON blob itself has any literal `</script` sequence
escaped to `<\/script` (invisible to JSON parsing, but not to the HTML
parser, which would otherwise treat it as this very page's own closing
tag) — this guards the page's own structure. Separately, the JS that
renders each row HTML-escapes every field that is real text from the
analyzed code (a function name, an argument fingerprint — which is
built from a real argument *value*, so a string argument containing
`<`/`>`/`&` is entirely plausible) before it reaches `innerHTML` — this
guards against that text being interpreted as markup. Fingerprint lists
(`args`/`error_fp`/`callers`) are HTML-escaped once, server-side in Lua,
since they are rendered as pre-built HTML fragments rather than
assembled client-side.

## Use from another plugin

A first-class use case, not an afterthought — `lib.nvim.docmap` set the
precedent (see `lib.strategies.telemetry_wrap` for how lib.nvim itself
consumes this module from outside): every layout assumption below is an
option, not a lib.nvim-specific requirement.

```lua
local t = require("runtime-analysis.telemetry").new({ namespace = "lsp.nvim" })

t.wrap(require("lsp.servers"), "servers")
t.wrap(require("lsp.handlers"), "handlers", { only = { "definition", "hover" } })
t.start()

-- days later, from inside lsp.nvim:
local report = t.report({ since = "7d", top = 20 })
```

Four things make this work:

- **Persistence is namespaced.** `lsp.nvim`'s counts and `lib.nvim`'s counts are
  separate files with no merge logic. The namespace is **sanitized** before it
  reaches `cache.disk`, which builds its path as `dir .. "/" .. namespace ..
  ".json"` with no escaping — a namespace containing `/` or `..` would otherwise
  write outside the cache directory.
- **Reports are per-instance by default.** The cross-instance view is opt-in via
  `telemetry.instances()`, so a plugin never accidentally reports on another
  plugin's numbers.
- **Teardown is per-instance and idempotent.** Each instance restores only what
  it wrapped.
- **Two instances can share a function safely.** A function is wrapped at most
  once, globally; instances subscribe to the one wrapper
  ([`registry.lua`](registry.lua)). Nesting wrappers would double-count and, if
  the *inner* instance stopped first, leave the outer one holding a wrapper it
  would later reinstall as "the original" — instrumentation permanently on with
  nothing to notice it. Restore happens when the last subscriber detaches.

## Argument profiling, done honestly

What is stored is a **fingerprint**, never the arguments:

| Value | Stored as |
| --- | --- |
| `nil` / boolean / number / short string | the value itself |
| long string | truncated with an ellipsis marker |
| table | `<table:#3>` / `<table:map>` — shape, not contents |
| function / userdata / thread | `<function>` / `<userdata>` / `<thread>` |

Storing real argument values would mean writing file paths, buffer contents and
possibly tokens into `stdpath("cache")`. A profiler that quietly does that is a
security bug, not a feature.

**Cardinality is bounded.** The top `max_arg_values` (32) distinct fingerprints
are kept per function, plus an "other" bucket with a count and an honest
`distinct` total. A function called with 10 000 distinct paths costs 33 entries,
not 10 000 — otherwise the memory profile is a function of user data, which is
the most likely way this module becomes the performance problem it was built to
find.

The output names the pattern rather than leaving you to spot it:

```
fs.find_root                12 480 calls
    └  91 %  ("/repo/lib.nvim")
    └   6 %  ("/repo/mdview.nvim")
    └   3 %  <other: 47 distinct>
    ⓘ 91 % of calls share one argument — candidate for memoization (lib.lua.memo.memo / .lru)
```

The hint is suppressed below 20 calls and for zero-argument calls (`()` is
always 100 % dominant and never actionable).

## Sampling

`sample = N` (docs/ROADMAP.md §3.2) makes the expensive modes above —
timing, argument profiling, error fingerprinting — affordable on a hot
surface: only every `N`th call pays for them, every other call takes the
same counting-only path a plain `t.start()` already uses.

```lua
t.wrap(mod, "hot", { time = true, sample = 20 })   -- 1 in 20 calls timed
```

**`calls` is always exact, regardless of sampling.** It was already free
(0.014 µs, the row above) — sampling exists specifically to make the
*other* modes cheap, not to touch the one that already was. What sampling
actually estimates: `timing`'s mean/min/max are computed from the sampled
subset, and an argument or error fingerprint's own share (`91 % of ...`
above) is computed against that same subset's own total, not the true call
count — otherwise a real dominant pattern would look artificially rare
just because most calls were never examined. This is why the memoization
hint still fires correctly under sampling: the threshold and the share it
compares against are both measured in the sample's own terms.

**Structural, like `outermost_only`** — set at `wrap()`/`wrap_loaded()`
time, not toggleable later via `start()`'s own per-key selectors. If two
different telemetry instances both wrap the identical function with
different rates, the site uses the more eager (smaller) of the two, so
neither subscriber ever sees less than it asked for.

## Startup attribution

`:RATelemetry startup` (docs/ROADMAP.md §3.3) answers which *module* a
plugin's startup cost actually sits in — lazy.nvim already reports
per-plugin totals, so the value here is specifically the level below that.

```lua
-- In this plugin's own lazy.nvim spec. `init` is the right hook, not a
-- line in init.lua — see "Why `init`, and not init.lua" below.
{
  "StefanBartl/runtime-analysis.nvim",
  init = function()
    require("runtime-analysis.telemetry.startup").autostart()
  end,
}
```

Without lazy.nvim, the equivalent is a call as early in your config as you
can put it — the constraint is only ever "before the modules you want to
see are loaded".

```
startup attribution  —  stopped
  147 module(s) loaded · 82.3 ms total

  by plugin (module root), self time:
    telescope                        21.40 ms
    nvim-treesitter                  18.02 ms
    lib                               6.11 ms

  by module, self time (total in parentheses):
    telescope.builtin                 9.80 ms  (14.20)
    nvim-treesitter.configs           7.44 ms  (18.02)
```

**How it actually works, since the roadmap entry's own premise was half
wrong and worth correcting here.** That entry said "the lazy adapter
already knows exactly when each plugin loads, which is half the mechanism."
lazy.nvim does time each *plugin* — but checked directly against its own
source, it does **not** time individual `require`s: its module loader
resolves and `loadfile`s a module with no timing around it. And the `User
LazyLoad` autocmd the existing `telemetry.lazy` adapter hooks is the wrong
instrument twice over — it fires *after* `config()` has already run, and it
is per-plugin, not per-module. So this wraps the global `require` and times
every **cache miss** instead. Nesting falls out of a stack: a module's
*self* time is its total minus everything it required in turn, which is
what makes the output a waterfall rather than a list where every parent
double-counts its children.

### Why `init`, and not a line in init.lua

lazy.nvim's startup sequence runs **every** plugin's `init` function first,
in one pass, *before* it loads a single plugin (`loader.M.startup`: step 1
is init, step 2 is start plugins, step 3 is rtp plugins). So `init` is
already the earliest per-plugin hook that exists, and it captures
essentially every plugin module load without touching your config's entry
point at all.

That matters beyond convenience. This feature could have been shipped as
"paste this into the top of your `init.lua`" — or worse, as something the
plugin writes there for you on install. The second is the one to name
explicitly, because it sounds helpful and is not: **an uninstalled plugin
runs no code**, so it could never remove that line again. It would outlive
the plugin in a version-controlled file, and `init.lua` is frequently not
even the real entry point (a `lua/config/` tree, `init.vim`, or a
Nix-managed read-only file). A spec-level `init` has none of that: it lives
in the same block that declares the plugin, so removing the plugin removes
it, and there is nothing left to error or to clean up.

**Honest limits, all of them:**

- **Only modules required *after* `autostart()` runs are ever seen.**
  Anything already in `package.loaded` by then is invisible, not free.
  With the `init` hook above, that means lazy.nvim itself and whatever your
  config does before `lazy.setup()` — a small, fixed set, not your plugins.
- A `package.loaded` cache hit is not a load and is never recorded. It
  costs one table index; recording it would bury the real loads.
- Only the *global* `require` is wrapped. Code that captured a local
  reference to `require` beforehand, or that goes through `loadfile` /
  `package.loaded` directly, bypasses this entirely.
- A module that raises during load is still recorded and flagged
  (`errored`), and the error propagates verbatim.

`autostart()` stops itself at `UIEnter` — startup is over by then, and
leaving the wrapper installed would keep paying for something with nothing
left to measure. `start()`/`stop()`/`reset()`/`report()` are all available
directly if you want a different window.

## Plugin cost vs. use

`:RATelemetry cost` (docs/ROADMAP.md §7.2) — startup attribution above
answers "what did loading cost"; a telemetry report answers "how much is it
actually used." Combined: **the report that gets plugins deleted.**

```
cost vs. use — worst (expensive, underused) first

  legacy-widget.nvim              41.20 ms startup           3 calls  (0.1 calls/ms)
      matched module root(s): legacy_widget
  markdown.nvim                    9.80 ms startup       8 200 calls  (836.7 calls/ms)
      matched module root(s): markdown
```

**The join the roadmap entry treated as free is the reason this shipped
after §3.3 rather than alongside it.** Startup attribution groups by module
*root* — a plugin's own Lua namespace, `"markdown"` for
`require("markdown.buffer")`. Telemetry groups by *namespace* — a
caller-chosen label, usually the repo name, `"markdown.nvim"`. The two are
only sometimes the same string, and guessing when they match (stripping
`".nvim"`, fuzzy comparison) would silently attribute one plugin's startup
cost to a different plugin on a name collision — worse than reporting
nothing.

The actual join needs no guessing: `inst.resolved_modules()` already knows,
for every function that resolves to a real module path
(`wrap_loaded()`/explicit `module_id` only — a plain `wrap(tbl, "label")`
does not resolve, by the identical honest-limits rule that function's own
doc-comment already states), which real modules a namespace's own calls
live in. Reading the module root off those real paths and matching it
against startup's own per-root totals joins on the one thing both features
already track honestly — a real Lua module path, never a name that merely
looks similar.

**`startup_ms` is `nil`, never `0`, whenever cost genuinely cannot be
determined** — "unknown" and "measured at zero" are different claims, and
`:RATelemetry cost` names which of two reasons applies: no real module path
resolves for this namespace at all, or one does but it never appears in the
startup report (`autostart()` was not running, or it loaded too early to be
seen). New module:
[`lua/runtime-analysis/telemetry/cost_vs_use.lua`](cost_vs_use.lua) — a
pure join over already-collected data from both features, requiring
neither `telemetry.startup` nor a live instance to test in isolation.

## Error fingerprinting

`errors` (docs/ROADMAP.md §2.5) already counted how *often* a wrapped function
raised; it now also fingerprints *what* it raised — reusing the identical
bounded-cardinality machinery argument profiling uses above, literally the
same code, pointed at the error value instead of the call's arguments. "This
function fails 3 % of the time, always with the same message" becomes a
readable fact instead of a count with no shape:

```
net.fetch                    4 200 calls
      3 error(s)
      ✗  67 %  "connection timed out"
      ✗  33 %  "DNS resolution failed"
```

Fingerprinted the same way an argument is (see the table above — short
values verbatim, long strings truncated, tables by shape only), so a real
token or path accidentally embedded in an error message is bounded and
truncated the identical way a real one would be as an argument. Shares are
computed against the function's own `errors` count, not its total calls —
"67 % of *errors* were this one" is the readable claim; against total calls
it would usually round to a number too small to read anything into.

No new opt-in: it rides entirely on `errors`, the same flag that already
turns on counting-only error tracking. Nothing changes for a caller who only
ever reads `entry.errors` — `entry.error_fp` is additive, `nil` whenever no
error has actually been fingerprinted yet (including every function that
never opted into `errors` at all).

## Table tracking

Everything above counts *calls*. `inst.track_table(t, key, opts)` counts
per-key **reads and writes on a table** instead — not part of the original
roadmap, added after a user asked "how often was table X accessed with which
key, reading, writing":

```lua
local get, set = t.track_table(config, "config")

local host = get("host")          -- counted as "config[host] read"
set("host", "example.com")        -- counted as "config[host] write"
```

**Explicit accessor functions, not a transparent proxy — the design was
revised once, for a real reason worth stating.** A `__index`/`__newindex`
metatable proxy was the first shape this was built as. It has a severe,
easy-to-hit footgun: those metamethods only fire for keys the proxy's own
raw storage does not have, which means the proxy must *never* accumulate a
single real key of its own to keep counting working — which means
`pairs()`/`ipairs()`/`#`/every `vim.tbl_*` helper sees the proxy as
permanently, silently empty. A config table that looks completely normal
the moment before it is wrapped, and reports zero keys to any code that
enumerates it afterward, is a worse failure than this feature not existing
at all. So `t` itself is **never replaced or touched** — `track_table`
returns two functions, and a caller opts a specific call site into counting
by writing `get("field")`/`set("field", value)` there instead of
`t.field`/`t.field = value`. An explicit, visible change per call site, not
a silent global one; `t` stays a completely ordinary, fully enumerable table
throughout.

Mechanically, each distinct field wraps a trivial no-op through `wrap_fn`
exactly once — the identical "wrap once per distinct key, call many times"
discipline `runtime-analysis.usage`'s own command counting already relies
on — so repeated access to the same field accumulates on one registry site,
not a new one leaked per call.

**Values are never inspected, stored, or reported — only how often each
field was read/written.** The same "count, do not capture" posture argument
fingerprinting already takes, for the same reason: a config table is exactly
the kind of place a real token ends up, and this module has no business
knowing what one looked like, only that it was read.

```lua
local get, set = t.track_table(cfg, "cfg", { writes = false })  -- reads only
```

`opts.reads`/`opts.writes` (both default `true`) turn off a whole side
independently — a read-only table (most config) never needs write counting
at all, and there's no reason to pay for a registry site that would never
receive a call.

## Comparison across time windows

`report({ since = "7d" })` answers "how much, in the last week"; `compare()`
(docs/ROADMAP.md §4.2) answers "what changed since the week before that" —
day buckets were already stored for the first, so the second is a report
mode over the same data, not a new collection mechanism:

```lua
local cmp = t.compare({ days = 7 })   -- default 7
vim.print(t.compare_lines({ days = 14 }))
```

```
last 7d vs the 7d before that  —  4 200 calls vs 3 100 calls

  newly hot:
    + parse.block_at                           340 calls (silent before)

  went cold:
    - legacy.migrate                           was 90 calls, silent now

  changed:
    ↑ net.fetch                                800 -> 1 200 calls (+50 %)
    ↓ cache.lookup                              600 -> 400 calls (-33 %)
```

Every key seen in either window lands in exactly one bucket: **newly hot**
(silent before, called now), **went cold** (the reverse), or **changed**
(called in both — sorted by the size of the change, not alphabetically,
since that is the actual point of asking). A changed entry's percentage is
relative to its own previous count; a newly-hot or gone-cold entry gets no
percentage at all, since dividing by zero previous calls is not one.

**Honest limit, surfaced rather than silently wrong.** The previous window
is exactly as complete as `retention_days` allows — comparing two 7-day
windows needs 14 days of history, comparing two 20-day windows needs 40.
When `2 × days` exceeds `retention_days` (30 by default), older buckets in
the previous window may already be pruned, and both `compare_lines` and
`compare_markdown` render a visible warning line rather than a comparison
that quietly under-reports what the previous window actually held.

## Lifecycle reminder

Telemetry that gets switched on and forgotten is the failure mode this feature
invites. Once enough data exists the module says so — **once** — and says it
actionably:

```
[runtime-analysis.telemetry] lsp.nvim has been collecting for 7 day(s)
(48210 calls, 63 functions). Review with :RATelemetry lsp.nvim —
stop with :RATelemetry stop.
```

- Checked at flush time and once on `VimEnter`, **never on the hot path**. A
  reminder a few minutes late costs nothing; a clock read per wrapped call costs
  exactly what this design avoids.
- Fires once and persists that it fired, in the same cache entry as the counts.
  A reminder that reappears every session is a nag, and a nag gets muted.
- Both a time and a volume trigger, whichever comes first — 7 days of a
  barely-used function is not enough data; 50 000 calls in one afternoon is.
- Escalates once at 4× the configured duration, then stops for good.

## What to instrument, and what not to

**Deliberately not instrumented:**

- Functions called in a **fast event context** (libuv callbacks). The hot path
  here stays at "increment an integer, maybe compute a fingerprint" precisely so
  a wrapper is safe there — but `lib.nvim.fs.mkdirp` exists because that context
  is hostile, and telemetry must not reintroduce the problem it solved.
- **Hot inner helpers** where the wrapper dominates the callee
  (`lib.lua.tables.core` primitives). Wrapping a three-line function to measure a
  three-line function measures the wrapper. Instrument the *public* surface.
- **Recursive functions**, unless you decide what you want: every entry is
  counted by default (documented, not accidental); `{ outermost_only = true }`
  collapses a recursive chain to one count, at the cost of a `pcall` per call.

## Honest limits

- Only calls that go **through the wrapped table** are seen. A consumer that did
  `local trim = lib.strings.trim` before `start()` holds the raw function and is
  invisible. Start as early as possible. (Same blind spot `proc_trace` documents
  for `local system = vim.fn.system`.)
- Counts are per-process, but every flush **re-reads and merges** what is on
  disk, so two Neovim instances sharing a namespace add up rather than clobber
  each other.
- Wrapping changes identity: after `start()`, a reference saved earlier is no
  longer `==` the table's current value. `stop()` restores exactly.
- Day bucketing reads the clock once per flush, not per call, so calls in the
  last flush interval before midnight land in the previous day.
- Timing reports `min`/`mean`/`max`. No `p95` — that needs a histogram per
  function, which is a different size/accuracy trade-off than this module makes.

## Not implemented

`wrap_tree(prefix)` — hooking `require` so lazily-loaded submodules are caught
automatically. Deliberately last: strictly more powerful and strictly more
ways to surprise, notably around `package.loaded` identity. Use explicit
`wrap()` calls per module.

**Manual mitigation, not the same feature:** `:RATelemetrySetupAll`/`Full`
re-runs `wrap_loaded()` on demand (`telemetry.setup_all`, above) — it picks
up whatever is loaded *at the moment it runs*, once, not automatically as
`require` happens. Good enough for "I just used a feature of this plugin
for the first time this session, now go make sure its module is wrapped";
not a substitute for genuinely automatic tree-wide catching.

## Files

| File | Role |
| --- | --- |
| `init.lua` | instance factory, scoping, lifecycle, module-level registry |
| `registry.lua` | the one shared wrap layer; instances subscribe to a site |
| `store.lua` | persistence, namespace sanitization, merge-on-write, day buckets, pruning, module-id map, read-without-an-instance |
| `fingerprint.lua` | argument → bounded, non-secret string key |
| `startup.lua` | startup attribution: wraps `require`, times each cache miss, self-vs-total waterfall (standalone — no instance, no namespace, no persistence) |
| `cost_vs_use.lua` | joins `startup.lua`'s per-root cost against a namespace's own `resolved_modules()`, on real module paths only — never a name guess |
| `report.lua` | report building + rendering (terminal lines and Markdown), incl. the memoization hint |
| `report_file.lua` | where a rendered Markdown *or* HTML report lives on disk, and writing one there |
| `report_style.lua` | resolve `report_style` ("auto"/"kit"/"mdview"/"file"/"html") to a concrete destination |
| `renderers/mdview.lua` | bridges a report to a browser tab via mdview.nvim's `:MDView standalone` |
| `renderers/html.lua` | the sortable/filterable HTML dashboard (§4.4) — a small, self-contained page, not documentation.nvim's own renderer reused |
| `config.lua` | module-level defaults (`report_style`) via `telemetry.setup()` |
| `reminder.lua` | the time/volume lifecycle trigger |
| `toggle.lua` | persistent per-namespace enable/disable, independent of an instance's own data |
| `lazy.lua` | the lazy.nvim adapter: catch-up scan + `User LazyLoad` autocmd, plus `configured()`/`candidates()` for `setup_all.lua` |
| `setup_all.lua` | `:RATelemetrySetupAll`/`Full`'s mechanism: backup + reset + re-wrap + restart across every configured, loaded plugin |
| `command.lua` | `:RATelemetry`, `:RATelemetryStartAll`/`StopAll`/`ResetAll`/`SetupAll`/`SetupAllFull` (opt-in `setup()`) |
