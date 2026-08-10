# Loaded-vs-declared

`runtime-analysis.loaded` — what is actually on a module's table right
now, in the current process, as opposed to what the source declares.
documentation.nvim's own static scan structurally cannot answer this: a
callback bound as a value, a metatable-materialized field, a key built
from a loop all look identical to "never happened" from source alone.

## Live read, joined by documentation.nvim

`M.functions(module_id)`/`M.is_loaded(module_id)` read `package.loaded`
directly — no wrapping, no instrumentation, called on demand, never on a
hot path. documentation.nvim's own `core/loaded_diff.lua` joins the result
against its IR for `:DocBrowse loaded` mode: declared-but-not-loaded and
loaded-but-not-declared, each a real discrepancy in its own direction.

The one honest limit that shapes all of it: this reads `package.loaded` in
the current process only. A tree analyzed from a process that never
actually loaded it sees nothing, which renders as "not loaded here", never
as "declared but dead" — a distinction only a live session can draw.

- **Module:** `loaded.lua`
- **Docs:** [`../../README.md`](../../README.md#loaded-vs-declared),
  `doc/runtime-analysis.txt` `*runtime-analysis-loaded*`.

## Persisted snapshots, for cold viewing

`:RA loaded snapshot <prefix> [name]` captures every currently-loaded
module under `prefix` — the same scoping `wrap_loaded(prefix)` already
uses — as a named, persisted snapshot, so it can be read later, or from a
different process entirely. The parallel to `runtime-analysis.telemetry`'s
own named snapshots, applied to a different kind of runtime fact: same
`lib.nvim.cache.disk` storage, same retention/eviction policy, same
"always explicit — nothing snapshots on its own" posture.

**One identifier, not two, unlike telemetry.** A telemetry namespace can
genuinely differ from the module prefix it wraps; a loaded snapshot has
nothing to name except the prefix it was captured under, so `M.snapshot`
takes no separate namespace argument — documentation.nvim's own reading
side derives the identical prefix independently from `opts.source`, never
told which one was used.

documentation.nvim's Loaded Analysis panel (`:DocMap serve`,
`GET /api/loaded`) is the consumer this was built for: a server route
answering a browser tab has no live `package.loaded` of its own to read,
so it only ever reads named snapshots — never a "latest" fallback the way
its Telemetry panel counterpart has one.

- **Module:** `loaded.lua` (`M.snapshot`, `M.list_snapshots`,
  `M.load_snapshot`)
- **Usercmds:** `:RA loaded snapshot <prefix> [name]`, `:RA loaded
  snapshots <prefix>`
- **Docs:** `doc/runtime-analysis.txt` `*:RA-loaded-snapshot*`; decision
  record in [`../FINISHED.md`](../FINISHED.md) (§5.4).
