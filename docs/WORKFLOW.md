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

Do the work, let real usage accumulate, then `telemetry.load_snapshot(ns,
"pre-refactor")` against the current `telemetry.load(ns)` (or, from
documentation.nvim's side, its own Telemetry Analysis panel's "Compare
vs:" picker) — the diff is the actual answer to "did this change what
gets called," not a guess read off two snapshots that both postdate the
change. Retention is LRU (`telemetry.SNAPSHOT_RETENTION`, default 20,
overridable per namespace via `opts.snapshot_retention` on `telemetry.new`)
— a snapshot worth keeping past that window needs a name that will still
mean something a dozen snapshots later, since eviction has no way to know
which ones you actually meant to keep.

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
