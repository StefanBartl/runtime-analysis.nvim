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

### §2.3 curl import / export

Paste a `curl` command line, get a request buffer; the reverse for sharing
— the roadmap entry's own framing, and its own verdict on which half
matters more held up while building it: import is real argument parsing
(a genuine, if bounded, tokenizer), export is a formatter over data this
plugin already has in hand.

New module, [`lua/runtime-analysis/curl.lua`](../lua/runtime-analysis/curl.lua).
No shared shell-tokenizer existed anywhere in lib.nvim (checked before
writing one) — `usercmd.composer`'s own tail-splitting is a plain
`gmatch("%S+")` with no quote awareness at all, so this module's own
`tokenize` is new: single-quoted strings literal (bash semantics — not
even a backslash is special inside one), double-quoted strings recognizing
only `\"`/`\\`/`` \$ ``/`` \` ``, an unquoted backslash escaping exactly
the next character, and adjacent quoted/unquoted segments joining into one
token the way a real shell's word-splitting does. Bash line continuations
(`\` at end of line) are joined before tokenizing, since a real multi-line
"copy as cURL" paste is exactly that shape.

`M.parse` recognizes `-X`/`--request`, `-H`/`--header` (repeatable),
`-d`/`--data`/`--data-raw`/`--data-binary`/`--data-ascii`
(repeatable, joined with `&` — curl's own behavior), `-u`/`--user` (become
a real base64-encoded `Authorization: Basic` header, the identical
value-add `parse.lua`'s own `Auth:` shorthand already provides for a
hand-typed request), `-b`/`--cookie`, `-A`/`--user-agent`, `-e`/`--referer`,
`--url`, a table of value-flags curl understands but this plugin has no
representation for (`-o`, `-w`, `-m`, `--connect-timeout`, TLS material, …
— consumed along with their value so it is never mistaken for the URL),
and a table of boolean flags (`-s`, `-v`, `-L`, `--compressed`, …) dropped
outright. **Method defaults exactly like real curl's own do**: any
`-d`/`--data` present with no explicit `-X` implies `POST`, not left as a
`GET` with a body for the reader to notice.

**One real, honest limit, stated rather than silently gotten wrong**: an
unrecognized value-flag (one curl understands that isn't in this module's
own table) is treated as boolean rather than risk swallowing the real URL
as its argument — the safer of two wrong guesses, since the result is a
visibly garbled request rather than a silently missing one.
`--data-urlencode`'s own URL-encoding step is not replicated either, for
the identical reason: a `key=plain-value` case still comes out identical,
and a value that actually needed encoding comes out visibly wrong rather
than silently mis-encoded.

`M.format` is the reverse: a request table back into a multi-line,
shareable `curl` command line, headers sorted for deterministic output.
Single-quote escaping is this module's own (the standard POSIX `'\''`
trick), deliberately not `vim.fn.shellescape` — that escapes for Neovim's
own `&shell`, cmd.exe/PowerShell syntax on this development machine, which
is simply the wrong grammar for a curl command meant to be pasted into any
real shell or shared verbatim in a doc.

**`M.format` never resolves `{{var}}` placeholders — the identical trap
§2.1's own entry names, closed the identical way.** `do_export`
(`bindings/usrcmds.lua`) hands it the raw request straight from
`parse.parse`, the same one `send_current_buffer` keeps unresolved for
history and the "sending ..." placeholder. Exporting is sharing, and a
`{{token}}` must render as `{{token}}` there too, not the value it would
resolve to.

**New commands: `:RA import` (`range = true`) and `:RA export`.**
`:RA import` with a real visual/line-range invocation reads the selected
lines; a bare invocation reads the system clipboard (falling back to the
unnamed register) — "paste a curl command," the roadmap entry's own
framing, taken literally for the common case of nothing selected. Parses
into a new buffer via `ra.open_request`, the identical entry point
documentation.nvim's own Endpoints mode already uses. `:RA export` resolves
the `###` block under the cursor (the same resolution `:RA send` already
uses) and yanks the formatted command to the unnamed register, mirroring
`:RA yank`'s own register convention for the response body.

Verified: `curl_spec.lua` — the tokenizer's four quoting/escaping rules
directly; `parse`'s data-implies-POST default and `-X`'s override of it;
repeated `-d` segments joining with `&`; `-u` becoming a real
base64-encoded header; an ignored value-flag (`-o`) not swallowing the
real URL; a missing URL producing a real error, not a silent empty string;
`format` omitting `-X` for `GET`, sorting headers, and escaping an
embedded single quote; and a full parse → format → parse round-trip
proving `format`'s own output is valid input to this module's own
tokenizer.

### §2.1 Variables and environments

`{{baseUrl}}/users/:id`, resolved from a per-project environment file — the
single feature that separates "I can send a request" from "I keep my
requests in this repo", now that §1 is fully shipped and the runner is
daily-use material. The roadmap entry's own trap, stated up front: an
environment file is where a real API token ends up, and it must never leak
into anything this plugin writes to disk or shows on screen incidentally.

Two per-project JSON files at the project root, the same split IntelliJ's
HTTP Client already uses for exactly this problem — matched rather than
invented, the same reasoning `parse.lua`'s own request shape already
follows: `http-client.env.json` (shared, safe to commit) and
`http-client.private.env.json` (gitignored — `.gitignore` in this
repository's own root now lists it). Both optional, merged per environment
name with the private file's own keys winning on overlap, so a project
committing only the shared file still gives every reader working defaults.

New module, [`lua/runtime-analysis/env.lua`](../lua/runtime-analysis/env.lua):
`load_all`/`list_names`/`current`/`set_current`/`resolve`. The active
environment is **session state, not saved state** — the same "a fact about
this editing session, not worth writing to disk" posture `:RA cancel`'s own
pending-request tracking already takes, chosen for the identical reason.

**The trap, closed at the one place it actually matters:** `M.resolve`
substitutes `{{name}}` and is called exactly once, in
`send_current_buffer` (`bindings/usrcmds.lua`), immediately before a
request is handed to `runner.run_async` — every other read of `request` in
that function (the `→ sending METHOD url ...` placeholder, the pending-
request record, every `history.record` call) keeps the original,
unresolved table `M.resolve` never mutates. A `{{token}}` renders as
`{{token}}` in the response pane's "sending" line and in `:RA history`
forever after; only the one real outgoing request ever sees the value it
resolved to.

A request with no `{{placeholder}}` at all resolves to an unchanged copy
with no error even with no environment ever selected — the common case
(a plain hardcoded request) is entirely unaffected by this feature
existing. Referencing a variable with nothing selected, or one the selected
environment doesn't define, is a `vim.notify` error naming exactly which
variable and which environments are available — never a silent `{{name}}`
handed to curl as a literal string that would just fail unhelpfully
downstream.

**New command: `:RA env [name]`.** With a name, selects it directly (or
reports the available ones if it doesn't exist); with none, `vim.ui.select`
over every name the project's files define — the same picker `:RA history`
already uses, for the identical "pick exactly one thing" shape.
`<Tab>`-completed via a small custom composer arg type
(`RA_ENV_NAME`, registered in `bindings/usrcmds.lua`) whose completer reads
`env.list_names()` live rather than a static enum, since the set of names
is data on disk, not something knowable when the command is registered.

**One safety net past the roadmap entry's own literal scope, added while
building it:** `M.load_all` warns once per session (`vim.notify`, `WARN`)
if `http-client.private.env.json` exists on disk but its filename does not
appear anywhere in the project's own `.gitignore` — a substring check
against that file's raw content, not a real gitignore pattern matcher (a
broader rule like `*.private.env.json` would also cover it and this check
would still warn), so it is a nudge worth heeding, not a guarantee. Stated
plainly as a scope addition, not a silent one: the roadmap entry only said
the file "must be gitignore-able by default," not that this module should
itself check.

Verified: `env_spec.lua` — file-merge precedence (private wins on
overlap, either side's unique keys survive), `set_current` rejecting an
unknown name and naming the available ones, `resolve`'s three shapes (no
placeholders at all → unchanged pass-through with no environment required;
a placeholder with nothing selected → named error; every variable present
→ substituted url/headers/body with the original request table provably
unmutated afterward), and a placeholder the selected environment doesn't
define → a named error, not a silent literal. Every case passes an
isolated `opts.root` so the suite never touches this repository's own real
`.gitignore` or project root — the identical isolation `history_spec.lua`
already gets from its own `opts.dir`.

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

### §1.3 Request history

Nothing was saved between sends. The obvious shape was
`lib.nvim.cache.disk`-backed, per-project (`lib.nvim.fs.project_key`
already computed that key), listing method/URL/status/timestamp, with
"reopen this as a buffer" as the one interaction that matters — and the
roadmap entry's own open question, decided as part of shipping it rather
than left for later: **request-only**, response bodies not stored at all
(not even behind an opt-in — "if at all" turned into "not this time").

New module, [`lua/runtime-analysis/history.lua`](../lua/runtime-analysis/history.lua):
`record`/`list`/`clear`, namespaced per project the same way the roadmap
entry specified, capped at `MAX_ENTRIES` (200, exported specifically so a
test could reference it instead of duplicating the magic number) with the
oldest dropped first — the identical "cardinality is bounded" discipline
`runtime-analysis.telemetry`'s own argument fingerprinting already applies,
applied here for the same reason.

**Extended past the roadmap entry's own literal scope, on reflection while
building it:** the entry named response bodies as the thing to keep out;
building this made it obvious that a request *header* is at least as
likely a place for a real secret to live — the `Auth:` shorthand's entire
reason for existing is that `Authorization: Bearer <token>` headers are
completely ordinary in real request buffers. Headers are not recorded
either, on either side, and this is stated as a deliberate widening of the
original decision, not a silent scope change.

**New commands: `:RA history`, `:RA history clear`.** The picker is
`vim.ui.select`, not the quickfix list documentation.nvim's own commands
favor — "pick exactly one thing and act on it" is a different shape of
question than "here are locations to jump through," and `vim.ui.select`
defers to whatever picker UI (telescope, fzf-lua, snacks, or Neovim's own
default) the reader already has configured rather than this plugin
inventing its own. Picking an entry reopens it via `open_request` —
exactly documentation.nvim's own Endpoints-mode integration, since a
history entry is, by design, precisely that much information.

**Every outcome recorded exactly once**, including cases the roadmap entry
never anticipated because they did not exist when it was written: a
*superseded* send (discarded by `:RA send`'s own §1.1 supersession) still
has its real eventual result recorded once known, since the request
genuinely happened even though nothing rendered it; a cancelled send is
recorded at cancel time with `note = "cancelled"` specifically so it is
never double-recorded when its late, now-irrelevant reply also arrives.
Distinguishing "superseded" from "cancelled" at the point a response
arrives needed comparing the token that requested it against the current
pending token, not just checking whether the request was still current —
the same token, but read two different ways for two different questions.

**A real bug found by the test suite, not by inspection**: `note =
status and nil or note` — the classic Lua `a and b or c` trap. Because `b`
(`nil`) is itself falsy, the `or c` branch always won regardless of `a`,
so `note` was never actually being dropped when a real status was present.
Replaced with an explicit `if`. The spec that caught it
(`history_spec.lua`) is now the reason it cannot regress silently again.

Verified: `history_spec.lua` against an isolated `opts.dir` per case
(status/note mutual exclusion, newest-first ordering, the `MAX_ENTRIES`
cap dropping the oldest and keeping the newest, clearing); an
integration block in `usrcmds_spec.lua` confirming `:RA send` and `:RA
history clear` actually call into the module through the real command
path; and a manual end-to-end pass with `vim.ui.select` stubbed,
confirming a real send records the real status and picking the resulting
entry reopens exactly `METHOD url`.

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
