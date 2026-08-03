# runtime-analysis.nvim — finished work

What shipped, and the trade-off behind it — the decision record
[`docs/ROADMAP.md`](ROADMAP.md) deliberately is not.

**The convention this file exists to keep:** when an item in `docs/ROADMAP.md`
ships, it is removed from there — not left behind as a struck-through "Done"
note that would otherwise make that document grow without bound — and
archived here instead, in full, with whatever reasoning made it worth
recording. `docs/ROADMAP.md` stays a living, readable backlog; this file is
the paper trail behind what is no longer on it. The same three-way split
[documentation.nvim](https://github.com/StefanBartl/documentation.nvim)
already draws between its own `FEATURES.md`/`ROADMAP.md`/`IDEAS.md` — this
file plays `FEATURES.md`'s role here, `docs/ROADMAP.md` plays its own, and
`docs/IDEAS.md` plays `IDEAS.md`'s.

A `§`-number below (e.g. "§2.2") points at the section that item used to
occupy in `docs/ROADMAP.md` — the number is not reused, so old cross-links
and commit messages that cite it still mean the same thing; it simply no
longer resolves to a section in that document. Housekeeping items (which
were never numbered) are named directly.

Newest first, by date; original document order within a date.

---

## 2026-08-04

### §1.1 Async sending

`:RASend` blocked until the response arrived — fine for a request bounded
in milliseconds, genuinely bad for a slow endpoint, since the editor froze
with no way to cancel. `lib.nvim.net.curl` already had a non-blocking
`fetch_raw` alongside the `fetch_raw_blocking` the blocking path used; the
work turned out to be exactly where the original roadmap entry said it
would be — the view, not the transport.

`runner.lua` gained `M.run_async(request, cb)`, sharing its response
formatting with `M.run` via a single `format_response(resp)` local rather
than duplicating it. One real finding while building it: `fetch_raw`'s own
completion callback fires in a **fast event context** — verified directly
(a bare `nvim_create_buf` call inside it raises `E5560`) rather than
assumed — so `run_async` wraps its own callback in `vim.schedule` itself,
once, rather than documenting that requirement and hoping every future
caller remembers it.

`:RA send`/`:RASend` now show a `→ sending METHOD url ...` placeholder in
the response pane immediately, and a `lib.nvim.progress` indicator
(soft dependency, `pcall`-guarded — sending still works with no visible
spinner if it is ever unavailable). Pending-request tracking lives in
`bindings/usrcmds.lua` as a monotonic token: firing a new `:RA send`
before an earlier one has replied bumps the token, and a response only
ever renders if its token is still current when it arrives — a *logical*
supersession, not a queue and not an "already in flight" refusal.

**New: `:RA cancel`.** Discards the in-flight request's eventual result the
same way a superseding send does (bumps the token via the progress
handle's own `on_cancel`/`request_cancel` wiring, so an interactive
progress style's own cancel gesture would go through the identical path,
even though none is configured by default) and shows `✗ cancelled`
immediately. **A logical cancel, not a process kill** — `fetch_raw` does
not hand back the `vim.SystemObj` a hard kill would need, so the
underlying `curl` process keeps running to completion in the background;
only this plugin's interest in its result is withdrawn. Extending
`lib.nvim.net.curl` to expose that handle is real, separate work in a
different repository — the same kind of extension this plugin already
motivated once (`fetch_raw`/`fetch_raw_blocking` themselves) — not
attempted here.

Verified end-to-end, not only at the unit level: a hermetic local server
whose replies are deliberately delayed, so tests could assert on the
*non-blocking* return, on supersession (two sends racing, only the second
ever rendering), and on cancellation (a late reply from an
already-cancelled request never overwriting the cancelled message) without
relying on timing luck. One real environment finding surfaced by this pass:
a closed local port takes ~2 seconds to report "connection refused" on
this environment (Windows' TCP stack retries before giving up, unlike
Linux's near-instant RST) — the async failure-path test's own timeout was
sized to that, not to the sub-second timing every other test in this
plugin gets away with.

---

## 2026-08-03

### §1.2 Multiple requests per buffer (`###`)

Both sibling tools (VS Code REST Client, IntelliJ HTTP Client) separate
requests in one file with a `###` line, and a real `.http` file collected
over a project is a *file of requests*, not one — `parse.lua`'s own
doc-comment had flagged this as deliberately not attempted.

`runtime-analysis.parse.split(lines)` cuts a whole buffer into blocks on
every `###` line, the marker excluded from both sides — a pure separator,
never a name comment or a request line, so there is one rule to the
splitter rather than an ambiguity to resolve. `parse.block_at(blocks,
cursor_line)` then answers "which block is the cursor in": the last block
whose first line is at or before the cursor, so landing exactly on a `###`
line resolves to the block *above* it — "still the request you were
editing" rather than requiring the cursor inside a block's own lines.

`:RA send`/`:RASend` always run this resolution now, even on a
single-block buffer (no `###` at all splits into exactly one block
covering everything) — one code path, not a special case kept alive for
the common single-request buffer. **Always the block under the cursor,
never the whole buffer, never a picker** — the question the original
roadmap entry posed ("send the one under the cursor, or offer a picker?")
and had already answered "yes, almost certainly" before this was built.

`M.parse` itself gained no `###` awareness at all — it still parses
exactly one request out of whatever `lines` it is handed, the same
contract it always had. All the new logic lives in `M.split`/`M.block_at`,
and the caller (`bindings/usrcmds.lua`) is what decides which slice to
hand `M.parse`.

Verified end-to-end, not just at the pure-logic level: a real hermetic
local server recording which of two `###`-separated requests it actually
received, cursor moved between blocks, `:RA send` and the flat `:RASend`
alias both checked (`docs/TESTS/usrcmds_spec.lua`).

### §1.4 `.http` / `.rest` file support

Recognizing a real file on disk — so a project can commit its request
collection — turned out to be almost entirely free once §1.2 landed, exactly
as the original roadmap entry predicted ("mostly free... what it needs is
`###` first").

Verified rather than assumed: `vim.filetype.match({ filename = "x.http" })`
already answers `"http"` in stock Neovim, no plugin involved at all. The one
real gap was `*.rest` (IntelliJ HTTP Client's own extension for the
identical file shape), which Neovim does not resolve natively — closed with
[`ftdetect/runtime-analysis.lua`](../ftdetect/runtime-analysis.lua), a
three-line `vim.filetype.add({ extension = { rest = "http" } })`. Sourced
automatically by Neovim's own `:filetype on` (every `ftdetect/*.lua` on the
runtimepath is), independent of whether `require("runtime-analysis").setup()`
has run yet — the same reason a plugin lazy-loaded on `ft = "http"` needs its
filetype detected before it can ever load on it.

Nothing else needed to change: `:RA send`/`:RASend` already read "the
current buffer" regardless of how it was opened, so a real file opened
directly with `:e requests.http` hits the identical code path a scratch
buffer from `:RA request` does. Not owning the `.http`/`.rest` filetype
outright — `docs/ROADMAP.md`'s own "Deliberately not building" table already
states that rule — this only teaches Neovim that `.rest` means the same
thing `.http` already does.

Verified end-to-end against a real file on disk (not just `vim.filetype.match`
in isolation): a `.rest` file with two `###`-separated requests, opened with
`:e`, cursor moved, `:RA send` — confirmed the right one was sent.

### §2.2 A response pane worth reading

Today it was status + headers + body as plain lines. `runner.lua`
pretty-prints a `Content-Type: application/json` body via
`lib.lua.json.encode.pretty` — the real, correct, pure-Lua encoder that
makes this safe now where the module's own earlier doc-comment explains
`vim.json.encode(value, { indent = N })` was tried and rejected first (it
does not actually indent — it inserts the literal text of `N` before each
key). Decode/encode failures fall back to the raw body verbatim rather than
erroring: a `Content-Type` header is a claim a server can get wrong, not a
guarantee.

`view.lua` sets `filetype = "json"` and turns on `foldmethod = "indent"`
when the body is JSON, reset to plain on every call so a later non-JSON
response in the same reused window never inherits either. A new subcommand,
`:RA yank`, copies just the body — using a `body_start` line number
`runner.lua` now returns alongside the lines, rather than a second parse of
them — to the unnamed register.

**Cut from scope, and why:** true per-content-type *syntax highlighting*
(HTML/XML/CSS bodies, not only JSON) needs the response buffer split into a
preamble region and a body region with its own embedded syntax — the whole
buffer cannot simply switch `filetype` per content-type the way it does for
JSON, because the status/header preamble is not valid content of any of
those types, and setting the whole buffer's filetype degrades everything
above the body to unhighlighted plain text. JSON's own case shipped anyway
because the folding is genuinely harmless there (indent-based, so unindented
preamble lines simply never fold) and the body is normally the larger,
more-important part of the buffer — but generalizing this to more content
types is real, separate work (a `syntax region`/embedded-syntax file), not a
small extension of what shipped here.

### §2.4 Auth helpers

Bearer/Basic as one line rather than a hand-written header. A header named
`Auth:` (`parse.lua`'s `resolve_auth_shorthand`) resolves into a real
`Authorization` header. `Auth: Bearer <token>` passes through verbatim (the
shorthand's value is purely that `Bearer`/`Basic` read as a matched pair, not
that Bearer itself got shorter). `Auth: Basic <user>:<pass>` base64-encodes
the credentials via `lib.lua.strings.encoding.base64_encode` — the actual
value-add, since RFC 7617 requires the base64 form and computing it by hand
is the annoyance this removes. `Auth: Basic <already-base64>` (no `:` in the
value — base64's own alphabet never contains one) passes through unencoded,
so a value copied from somewhere else still works. An unrecognized scheme
after `Auth:` passes through as the `Authorization` value unmodified, a
generic fallback rather than an error.

OAuth *flows* (redirect, token refresh) remain explicitly out of scope, as
originally scoped — a different, much larger problem this plugin is not
taking on.

### §4.1 A CLI / headless entry point

`nvim --headless -l scripts/telemetry.lua report lib.nvim` — read a
namespace off disk with no editor session. Shipped as
[`scripts/telemetry.lua`](../scripts/telemetry.lua): `report <namespace>` and
`export <namespace> <path>` (`--since`/`--top`/`--sort`/`--dir`), built
entirely on `telemetry.load()` + `report.build()`, exactly as predicted — a
script and an argument parser, no new analysis. `export`'s `.md`-vs-anything-
else format inference mirrors `:RATelemetry export`'s own rule, one rule to
remember rather than one per entry point.

**`coverage` deliberately not included**, a scope cut found while building
this rather than assumed up front: "which registered functions were never
called" needs to know the *registered* set, and only a live instance's own
`wrap()` calls establish that. A cold `telemetry.load()` read has no way to
answer it — promising `coverage` here would be a CLI command that lies about
what it can see.

Bootstraps lib.nvim onto the runtimepath with the same three-candidate search
(`LIB_NVIM_DIR`, `.deps/lib.nvim`, a sibling checkout) `docs/TESTS/run.lua`
already uses, duplicated rather than shared between the two entry points —
small enough that a shared helper module would add more indirection than it
saves for two call sites.

Found and fixed while building this: `nvim -l script.lua`'s `arg` table has
no `table.unpack` on this Neovim's bundled LuaJIT (Lua-5.1-shaped here
despite the global `unpack` existing) — the argument splitter takes a start
index into `arg` instead of slicing it via `table.unpack`.

### `:checkhealth runtime-analysis`

Is `curl` present, is `lib.nvim` the version this expects, is the telemetry
cache directory writable, is mdview available for `report_style = "auto"`.
Shipped as [`lua/runtime-analysis/health.lua`](../lua/runtime-analysis/health.lua),
modeled on documentation.nvim's own `editor/health.lua`: reports resolved
configuration (live telemetry instances, persistently disabled namespaces,
the cache directory and whether it is writable) rather than only
presence/absence.

### Vimdoc

Both sibling plugins had one; this had a README and nothing `:help` could
find. Shipped as [`doc/runtime-analysis.txt`](../doc/runtime-analysis.txt),
`doc/tags` gitignored (generated by `:helptags`, not committed — the same
convention documentation.nvim and mdview.nvim both already use).

### `docs/COMMANDS.md` + `docs/BINDINGS.md`

A `docs/COMMANDS.md`, once there are more than three commands —
documentation.nvim's is the model. Both shipped in the same pass:
[`docs/COMMANDS.md`](COMMANDS.md) and [`docs/BINDINGS.md`](BINDINGS.md), the
latter required by `NEW_PROJECT.md`'s own checklist and not existing at all
before this.

### Compound `:RA [subcommand]` usercommand

Per `NEW_PROJECT.md` §5's own preferred shape. Shipped as
[`lua/runtime-analysis/bindings/usrcmds.lua`](../lua/runtime-analysis/bindings/usrcmds.lua),
built on `lib.nvim.usercmd.composer` (the same module `:DocMap`/`:MDView`
use): `:RA request` / `:RA send`, `<Tab>`-completed. Later the same day,
gained a third route, `:RA yank` (§2.2 above).

Revised from an earlier "deliberately not done" verdict recorded the same
day: the original worry — that renaming `:RARequest`/`:RASend` would break a
user's own keymap to either name — turned out not to force a choice at all.
`:RARequest`/`:RASend` stay registered verbatim as flat aliases calling the
exact same handlers `:RA`'s routes do; nothing was renamed, only added to.
`:RATelemetry` stays a separate second compound command rather than folding
under `:RA telemetry ...` — see `docs/COMMANDS.md`'s own section on why, the
same split documentation.nvim draws between `:DocMap` and `:DocBrowse`.

### `config/init.lua` + `config/DEFAULTS.lua` + `bindings/` + a top-level `@types/init.lua`

Structural conformance to `NEW_PROJECT.md`'s own checklist. The single
`config.lua` became a folder (`require("runtime-analysis.config")` still
resolves to it unchanged, so no call site moved); `:RARequest`/`:RASend`'s
registration moved out of `init.lua` into `bindings/usrcmds.lua`. No
`keymaps.lua`/`autocmds.lua` were added beside it — this plugin sets
neither, by design, so there was nothing to move into either file.
