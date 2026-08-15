# Workflow — getting real use out of runtime-analysis.nvim day to day

Every command here is documented on its own elsewhere ([`README.md`](../README.md),
[`docs/COMMANDS.md`](COMMANDS.md), [`lua/runtime-analysis/telemetry/README.md`](../lua/runtime-analysis/telemetry/README.md)).
This is the different question: once several pieces exist — a request
runner, telemetry, the introspection commands — *how do they actually
combine* into something worth reaching for regularly, not just once after
install.

## Start from `:RA request`, not from a browser tab

The request runner exists because none of the reasons to reach for a
browser or Postman actually apply to a request Neovim itself can send:
no CORS, no separate process, no context switch. `:RA request` opens a
buffer, write the request in the same shape VS Code's REST Client uses,
`:RA send` from inside it. The response lands in a reused split beside the
request — never a new one, never stealing focus — so the loop is
edit → send → glance → edit again, not edit → alt-tab → read → alt-tab
back.

Add `# @expect status 200` once a request has to keep working, not just
once. It turns an ordinary `:RA send` into a smoke test — silent on a
match, a quickfix entry on a mismatch — cheap enough to leave in a
committed `.http` file permanently rather than writing a separate test for
"does the health endpoint still return 200."

## `.http` files are the collection; `:RA history` is the recall

Two different things worth not confusing. A `.http`/`.rest` file,
`###`-separated, `git`-committed, is the *deliberate* collection — the
requests this project's API actually has, written once, reused by anyone
who opens the file with `:e`. `:RA history` is the *incidental* record —
every send, across every ad-hoc `:RA request` scratch buffer too, request
only (method/url/status/timestamp, never headers or body — a header is
very often where the real secret lives). Reach for the `.http` file when
you know which request you want; reach for history when you remember
sending something like this recently but did not think to save it.
`:RA env dev`/`:RA env prod` switches which `{{baseUrl}}`-shaped
placeholders resolve to, read from `http-client.env.json`
(commit-safe) and `http-client.private.env.json` (gitignored — where a
real token belongs) — set this once per session, not per request.

## Copy as cURL in, `:RA export` out

`:RA import` turns whatever curl command is on the clipboard right now —
every API's own docs, every browser devtools "copy as cURL," produce
exactly this shape — into a real request buffer, editable and sendable
like any other. The reverse, `:RA export`, yanks the `###` block under the
cursor as a shareable curl command. Neither resolves `{{var}}`
placeholders, on purpose — the same reason `:RA env` keeps a literal
`{{token}}` in history rather than the value: a shared curl command with a
real secret baked in is a leak waiting to happen, and the placeholder
staying literal is what makes sharing it safe by default rather than safe
only if you remember to scrub it.

## Point telemetry at your own plugin before trusting a claim about it

```lua
local t = telemetry.new({ namespace = "my-plugin" })
t.wrap_loaded("my-plugin")   -- every already-loaded module, resolved automatically
t.start()
```

`wrap_loaded` over a manual `wrap()` per module whenever the target is a
real plugin already on `package.loaded` — it resolves `Data.modules`
automatically (the dotted `@module` path), which is what lets a consumer
like documentation.nvim's own `telemetry_join.lua` match a call count back
to a real function later, cold, in a different process. **Off costs
nothing, literally** — instrumentation is installed, not compiled in, so
"just leave it running" is a real option for a plugin you maintain, not
only a debugging session.

The one honest limit worth internalizing before reading any report this
produces: only calls that go *through* the wrapped table are seen. A
consumer that captured a bare function reference before `start()` ran
holds the original, invisible function — this is why `wrap_loaded`/`auto()`
belong as early in a plugin's own `setup()` as they can go, not bolted on
after the fact once something already looks slow.

## Snapshot before you start, not only after

`telemetry.snapshot(namespace, name?)`/`:RATelemetry snapshot <ns> [name]`
captures the current aggregate under a name, independent of the
continuously-overwritten live one. The habit worth building is naming one
*before* a change, not comparing two after-the-fact captures once you
remember to:

```
:RATelemetry snapshot my-plugin pre-refactor
```

Do the work, let real usage accumulate, then snapshot again and diff the
two directly — `telemetry.compare_snapshots(ns, "pre-refactor",
"post-refactor")` / `:RATelemetry snapshot-compare ns pre-refactor
post-refactor` — rather than hand-diffing `telemetry.load_snapshot()`
calls yourself (or, from documentation.nvim's side, its own Telemetry
Analysis panel's "Compare vs:" picker, if you'd rather stay in the
browser). The diff is the actual answer to "did this change what gets
called," not a guess read off two snapshots that both postdate the
change.

Read `changed`/`new_functions`/`cold_functions` by what they actually
measure, not by the day-window intuition `telemetry.compare()` (a
different function — "this week vs last week," over one dataset's own
rolling buckets) trains: `Data.functions[key].calls` is a lifetime
counter that only ever grows, so `cold_functions` here cannot mean
"never called" — it means "had calls before `pre-refactor`, zero *new*
ones since," which is the question two ordered snapshots can actually
answer.

Retention is LRU (`telemetry.SNAPSHOT_RETENTION`, default 20,
overridable per namespace via `opts.snapshot_retention` on `telemetry.new`)
— a snapshot worth keeping past that window needs a name that will still
mean something a dozen snapshots later, since eviction has no way to know
which ones you actually meant to keep.

Snapshots are device-tagged by default (`vim.uv.os_gethostname()`,
overridable via a third `telemetry.snapshot(ns, name, {device=...})`
argument, or `{device=false}` for none) — worth setting explicitly when
`pre-refactor` and `post-refactor` are captured on different machines,
since the names alone will not say which ran where later.

## The static × runtime join: read *this* side's data, not a guess from the other

documentation.nvim's own static scan can prove a function is *never
called from anywhere it can see* — never that it is dead. A function only
ever invoked through a `vim.keymap.set` callback value, or from a sibling
repo entirely, looks identical to genuinely dead code from a pure static
read. That is the entire reason this plugin exists next to it: telemetry
answers "was it *actually* called," the one question a static scan
structurally cannot. Read documentation.nvim's own
[`docs/WORKFLOW.md`](https://github.com/StefanBartl/documentation.nvim/blob/main/docs/WORKFLOW.md)
("If runtime-analysis.nvim is installed…") for the full badge vocabulary
(`✕`/`!`/`○`/blank) that join renders with — not repeated here, since it
is that plugin's own rendering, not this one's data.

## Pausing everything to isolate a performance question

`:RATelemetryStartAll`/`:RATelemetryStopAll` — standalone aliases for
bare `:RATelemetry start`/`stop` (no namespace), which already mean
"every live instance in this process." Reach for these when the question
is about the *editor*, not one plugin: stop everything, reproduce the
slowdown you are chasing, and instrumentation overhead is ruled out as a
cause for the whole session at once, rather than one `stop <ns>` per
plugin. `start` again afterward re-attaches every wrapper — cheap, since
nothing was ever recompiled, only swapped back out.

## "This function never shows argument data" — usually a late `require`, not a setting

`profile_args` is almost never the actual problem once it is already on for
a plugin (this config's own `lua/config/telemetry.lua` defaults it to `true`
for every personal plugin) — a function that still shows no `args` bucket
was very likely never wrapped in the first place, not profiled-without-args.
`wrap_loaded()` walks `package.loaded` exactly once, at catch-up-scan or
`User LazyLoad` time; a submodule the plugin `require`s *afterward* — a
command handler pulled in on first use, a UI module loaded on first
keypress — is invisible from that point on, permanently, until something
re-scans. Zero calls, no argument fingerprint, and nothing about it looks
like an error.

```
:RATelemetrySetupAll
```

re-wraps every configured, currently-loaded plugin (backing up and
resetting its data first — see below), which is exactly the fix: use the
feature whose module loaded late at least once, then rerun
`:RATelemetrySetupAll`(`Full`) and the newly-loaded functions join the wrap.

## Bulk backup + reset + restart, across every plugin at once

```
:RATelemetrySetupAll
:RATelemetrySetupAllFull
```

For every plugin `opts.telemetry.plugins` configures that is loaded right
now: if it already has data, back it up (one `vim.ui.input()` prompt for a
directory, for the whole run — not one per plugin; declining leaves
everything untouched rather than resetting some plugins without a backup),
`reset()`, re-wrap (see above), and restart. Plain `SetupAll` uses each
plugin's own configured `profile_args`/`timing`; `SetupAllFull` forces both
on for everyone regardless of individual policy — the bulk equivalent of
`:DocMap full`'s LuaLS enrichment one repo over: more expensive, invoked
on request, not left on by default. Reach for this at the start of a
deliberate measurement period ("I want a clean week of full-detail data
across everything"), not as a routine habit — `:RATelemetry snapshot`
(above) is the lighter-weight tool for "capture a point in time without
touching what's currently running."

## Two live instances, one namespace — a warning, not a crash

`telemetry.new({ namespace = "x" })` twice in the same process (a plugin
`require`d from two different places, a config that calls `setup()`
twice) warns rather than erroring — both instances write the same cache
file, silently double-counting anything both happen to wrap. The warning
names the namespace precisely so this is easy to grep for; the fix is
almost always "only one of these call sites should exist," not a
namespace rename.

## Argument profiling costs more than counting — sample if it matters

`t.wrap(mod, "name", { profile_args = true })` fingerprints every call's
arguments (bounded cardinality, so a function called with 10,000 distinct
paths does not become 10,000 stored entries) — genuinely useful for "what
does this actually get called *with*," genuinely more expensive than a
bare call count. `{ sample = N }` on the same `wrap()` call (1-in-N calls
pay for the expensive modes, every other call takes the same
counting-only path plain `t.start()` already uses) exists for exactly the
case where profiling on a hot path is worth the insight but not worth the
per-call cost at full resolution — `calls` itself stays exact regardless,
only the sampled modes (timing, argument/error fingerprints) estimate from
the subset. Reach for `sample` before turning `profile_args` off entirely
on a function that turns out to be hot.
