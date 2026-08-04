# Commands

One compound verb, two flat aliases, and one second compound command —
split along the same line documentation.nvim's own `docs/COMMANDS.md` draws
between `:DocMap` and `:DocBrowse`: `:RA` **does** something to a request,
`:RATelemetry` **reports** on what has already run.

None exists until `setup()` runs — `require("runtime-analysis").setup()`
registers all four unconditionally; there is no `opts.command_name` to
rename them yet, unlike the sibling plugins, because nothing here has hit a
collision that would motivate one (see the Global-surface collision check in
[`docs/BINDINGS.md`](BINDINGS.md)).

---

## `:RA request` (alias: `:RARequest`)

Opens a new scratch buffer (`buftype = "acwrite"`, `filetype =
opts.request_filetype`, default `http`), pre-filled with:

```
GET https://
```

Cursor lands at the end of that first line. `:RA request` always creates a
fresh, unnamed scratch buffer for a new one-off request — see "`###`:
multiple requests, and real files" below `:RA send` for the complementary
case, a committed file holding several.

`M.open_request(lines)` (the same function this command calls with no
argument) is also this plugin's public integration surface — see
`docs/IDEAS.md` and the module doc-comment in
[`lua/runtime-analysis/init.lua`](../lua/runtime-analysis/init.lua) for how
documentation.nvim's `:DocBrowse` Endpoints mode calls it with a pre-filled
`METHOD path` instead of the default template.

### The `Auth:` header shorthand

One header name is special-cased by `runtime-analysis.parse`:

```http
GET https://api.example.com/users
Auth: Bearer abc123
```

resolves to `Authorization: Bearer abc123` — passed through verbatim; the
shorthand's value here is purely that `Bearer`/`Basic` read as a matched
pair, not that `Bearer` itself got any shorter.

```http
GET https://api.example.com/users
Auth: Basic alice:s3cret
```

resolves to `Authorization: Basic <base64("alice:s3cret")>` — the actual
value-add, since RFC 7617 requires the base64 form and computing it by hand
is the annoyance this removes. `Auth: Basic <already-base64>` (no `:` in
the value — base64's own alphabet never contains one) passes through
unencoded, so a value copied from elsewhere still works unmodified. Any
other scheme after `Auth:` passes through as the `Authorization` value as
written — a generic fallback, not an error, for a scheme this shorthand
does not know about specifically.

A literal `Authorization:` header, written directly, is completely
untouched by any of this — the shorthand only intercepts the `Auth:` name.

## `:RA send` (alias: `:RASend`)

Run from inside a request buffer. Parses the buffer's lines
(`runtime-analysis.parse`) into `{ method, url, headers, body }`, sends it
via `lib.nvim.net.curl.fetch_raw` (`runtime-analysis.runner.run_async`), and
renders `STATUS status_text`, sorted headers, a blank line, then the body
into a persistent split (`runtime-analysis.view`).

**Non-blocking.** The editor stays responsive while curl runs — a
`→ sending METHOD url ...` placeholder appears in the response pane
immediately, replaced by the real response, an error, or a cancelled
message once one of those actually happens. A parse error is still
synchronous (nothing was sent yet, so there is nothing to wait for); a
transport failure (bad host, timeout) arrives through the same async path
as a real response and reports via `vim.notify` plus an `✗ error` line in
the pane. An HTTP error status (404, 500, …) is not an error at all and
renders as a normal response, exactly as before.

**A visible indicator, via `lib.nvim.progress`** — soft dependency,
`pcall`-guarded: sending still works with no visible spinner if it is ever
unavailable, just without the notification and without cancelling
*through the handle* specifically (`:RA cancel` still discards the result
directly in that case). The indicator is delay-guarded (invisible until
~150ms, the library's own default), so a fast response never flashes UI.

**Firing a second `:RA send` before the first replies supersedes it** —
a monotonic token bumped on every send; a response only ever renders if
its token is still the current one when it arrives. Never a queue, never
both responses rendering, never an "already in flight" refusal. This is
also exactly what `:RA cancel` does (see below), just triggered
differently.

The response split is reused across sends (looked up by buffer name, not
held in a module variable, so a stale reference after `:bwipeout` or a
`:source` during development cannot happen) and never steals focus from the
request buffer — the workflow is edit, send, glance, edit again, not
"switch to the response and back."

**A `Content-Type: application/json` body is pretty-printed** via
`lib.lua.json.encode.pretty` and the buffer's filetype becomes `json`
(real syntax highlighting and indent-based folding), reset to the plain
`runtime-analysis-response` filetype on the next call if that response is
not JSON — the window is reused, so nothing from an earlier response
lingers. A `Content-Type` header naming JSON is a claim, not a guarantee:
if the body does not actually decode, it renders raw and verbatim rather
than erroring or dropping content.

### `###`: multiple requests, and real files

A buffer (or a real, committed file) may hold more than one request,
`###`-separated — the same delimiter both VS Code's REST Client and
IntelliJ's HTTP Client use:

```http
GET https://api.example.com/users

###

POST https://api.example.com/users
Content-Type: application/json

{"name": "Bob"}
```

`runtime-analysis.parse.split` cuts the buffer into blocks on every `###`
line (excluded from both sides — a pure separator, never a request line or
a name comment); `parse.block_at` then resolves which block a 1-based
cursor line belongs to — the last block whose first line is at or before
the cursor, so landing exactly on a `###` line resolves to the block
*above* it. `:RA send`/`:RASend` always run this resolution first, even on
a single-block buffer (no `###` at all splits into exactly one block
covering everything) — there is one code path, not a special case for the
common single-request buffer. **Always the block under the cursor, never
the whole buffer, never a picker** — the answer `docs/ROADMAP.md` §1.2
already settled before this was built.

This is also what makes a **real, committed `.http` or `.rest` file** work
with no new command at all: open one directly with `:e requests.http` (or
`.rest` — see `ftdetect/runtime-analysis.lua`, since Neovim only resolves
`*.http` to the `http` filetype natively, not `*.rest`) and `:RA send`
already reads "the current buffer", origin-agnostic — a scratch buffer
from `:RA request` and a real file opened by hand hit the identical code
path.

## `:RA yank`

Yanks just the response **body** — not the status line or headers above it
— to the unnamed register (`"`), using the same `body_start` line number
`:RA send` computed when it rendered the response. Warns rather than
erroring when there is no response yet this session, or when the last
response had no body at all.

## `:RA cancel`

Cancels the in-flight request, if any: shows `✗ cancelled` in the response
pane immediately and marks its eventual result as stale, so whatever
`curl` returns afterward never overwrites that message. Warns (does not
error) when nothing is in flight.

**A *logical* cancel, not a process kill.** `lib.nvim.net.curl.fetch_raw`
does not hand back the `vim.SystemObj` a hard kill would need — the
underlying `curl` process keeps running to completion in the background;
only the plugin's own interest in its result is withdrawn. Extending
`lib.nvim.net.curl` to expose that handle is real, separate work in a
different repository (the same precedent `fetch_raw`/`fetch_raw_blocking`
already set once — this plugin was the reason those exist too), not
attempted here.

## `:RA history`

Opens a `vim.ui.select` picker (whichever picker UI is already configured
— telescope, fzf-lua, snacks, or Neovim's own default) over every send
this project has recorded, newest first, formatted as `date  status
METHOD url`. Picking one calls `M.open_request({"METHOD url", ""})` —
exactly documentation.nvim's own Endpoints-mode integration, since a
history entry *is*, by design, exactly that much information and no more.
Reports (does not error) when there is nothing recorded yet for this
project.

`vim.ui.select` rather than the quickfix list documentation.nvim's own
commands favor: this is "pick exactly one thing and act on it", not "here
are several locations to jump through" — the native pick-one primitive is
the right one for this shape of question.

### `runtime-analysis.history` — what is recorded, and what is not

Every `:RA send`/`:RASend` records one entry via
[`lua/runtime-analysis/history.lua`](../lua/runtime-analysis/history.lua):
**method, url, status, timestamp — nothing else, on either side.** No
headers, no body. This is the roadmap entry's own stated answer to its own
open question (request-only vs. also storing responses), extended one step
further: a request *header* is very often where the real secret actually
lives (an `Authorization: Bearer ...` value — the whole reason the `Auth:`
shorthand above exists), so it is left out on the request side too, not
only the response side the roadmap entry named explicitly.

Persisted via `lib.nvim.cache.disk`, namespaced per project by
`lib.nvim.fs.project_key()` (the Git root, or the cwd) — a `.http`
collection in one repository never shows up in another's history. Capped
at `history.MAX_ENTRIES` (200) total, oldest dropped first, the same
bounded-cardinality discipline `runtime-analysis.telemetry`'s own argument
fingerprinting already applies, for the identical reason.

**Every outcome is recorded, exactly once** — a real response, a transport
failure, an explicit `:RA cancel`, and even a *superseded* send's real
eventual result once it is known (the request genuinely happened, even
though nothing rendered it). A cancelled request is recorded at cancel
time with `note = "cancelled"`; everything else is recorded when the
outcome is actually known, never both, never twice for the same send.

**Honest limit, not silently worked around:** the url itself is stored
verbatim. A secret embedded in a query string (`?api_key=...`) is not
stripped — doing so generically and correctly is a real, separate problem,
not a small addition to a request-only history.

## `:RA history clear`

Clears the current project's history outright. No confirmation prompt —
the same posture `:RATelemetry reset` already takes for clearing
telemetry counts, and for the same reason: this data is disposable and
locally-scoped, not something a confirmation dialog meaningfully protects.

## `:RA env [name]`

`{{name}}` inside a request buffer's url, header values or body — `{{baseUrl}}/users/:id`
— resolves against a *named* environment (`dev`/`staging`/`prod`, or any
name a project's own files define), docs/ROADMAP.md §2.1. With an argument,
selects that environment directly (or reports the available names if it
doesn't exist, rather than silently doing nothing); with none, offers every
defined name via `vim.ui.select`, the same picker `:RA history` already
uses. **Session-scoped, not persisted across restarts** — which environment
you meant is a fact about the current editing session, not one worth
writing to disk.

### Where names and values come from

Two per-project JSON files at the project root — the same split IntelliJ's
HTTP Client already uses for exactly this problem, matched rather than
invented (the same reasoning `docs/ROADMAP.md`'s "Deliberately not: owning
the `.http` filetype" already gives for `parse.lua`'s own request shape):

```
http-client.env.json          shared, safe to commit — non-secret
                               defaults (a baseUrl, a tenant id)
http-client.private.env.json  gitignored, per-machine — the file a real
                               token belongs in
```

```json
// http-client.env.json
{
  "dev": { "baseUrl": "http://localhost:3000" },
  "prod": { "baseUrl": "https://api.example.com" }
}
```

```json
// http-client.private.env.json
{
  "dev": { "token": "..." },
  "prod": { "token": "..." }
}
```

Both files are optional and merged per environment name, the private file's
own keys winning on overlap: a project can commit only the shared file and
every reader still has working defaults; a reader who also drops a private
file next to it layers their own secrets on top of those, without either
file ever needing to know about the other's existence. `.gitignore`
already lists `http-client.private.env.json` in this repository's own root,
and `runtime-analysis.env` warns once per session (`vim.notify`, `WARN`) if
that file exists on disk but its name is not found anywhere in the
project's own `.gitignore` — a substring check, not a real gitignore
pattern matcher, so it is a nudge worth heeding rather than a guarantee.

### The trap this was built to avoid

Stated up front in the roadmap entry this ships: an environment file is
where a real API token ends up, and it must never leak into something this
plugin writes to disk or shows on screen incidentally. Resolution happens
**exactly once**, in `runtime-analysis.env.resolve`, immediately before a
request is handed to curl inside `send_current_buffer`
(`lua/runtime-analysis/bindings/usrcmds.lua`) — the raw, unresolved request
(`{{token}}` still literal) is what everything *else* reads: the
`→ sending METHOD url ...` placeholder and every `:RA history` entry both
show/record the placeholder text exactly as typed, never the value it
resolved to. A `{{token}}` renders as `{{token}}` everywhere except inside
the one real outgoing request.

A request with no `{{placeholder}}` at all is entirely unaffected by any of
this — `M.resolve` returns it unchanged, even with no environment ever
selected, so a plain hardcoded request works exactly as it always has.
Referencing a variable with nothing selected, or one the selected
environment doesn't define, is a clear `vim.notify` error naming exactly
which variable is missing — never a silent `{{name}}` sent to a real server
as a literal string.

## Response assertions (`# @expect status N`)

`docs/ROADMAP.md` §2.5: a smoke-test shape for a local API, deliberately
narrow — "is this endpoint still 200," not a general assertion language.
A comment line anywhere in a `###` block —

```http
# @expect status 200
GET https://api.example.com/users
```

(`// @expect status 200` also works, IntelliJ HTTP Client's own comment
style) — checked once `:RA send`'s real response arrives.
[`lua/runtime-analysis/assertions.lua`](../lua/runtime-analysis/assertions.lua)
extracts and strips the directive before `runtime-analysis.parse` ever
sees the block (that module has no comment syntax of its own). At most one
directive per block: a second is a real error, not "last one wins"
silently.

A match is a plain `vim.notify`; a mismatch — including a transport
failure, itself an automatic mismatch when a status was expected — replaces
the quickfix list (never auto-opened, the same "never steals focus" rule
`:RA send` itself keeps) with one entry pointing back at the directive's
own line, naming both the expected and actual status. `:copen` to see it.

## `:RA import` and `:RA export`

`docs/ROADMAP.md` §2.3: paste a `curl` command line, get a request buffer;
the reverse for sharing. Both are built on
[`lua/runtime-analysis/curl.lua`](../lua/runtime-analysis/curl.lua) — a
real (if bounded) `curl`-argument parser, not string templating.

```vim
:RA import
```

Reads the system clipboard (falling back to the unnamed register if empty)
and parses it as a `curl` command line — "paste a curl command," taken
literally, matching what a browser's own "copy as cURL" or an API's own
docs already put on your clipboard. Invoked with a real range instead
(`'<,'>RA import`, e.g. after visually selecting a `curl` snippet already
sitting in some buffer), reads the selected lines instead of the
clipboard. Parses into a fresh request buffer via `M.open_request` — the
same integration surface documentation.nvim's own Endpoints mode already
uses — rather than mutating the current one.

Recognizes `-X`/`--request`, `-H`/`--header` (repeatable),
`-d`/`--data`/`--data-raw`/`--data-binary` (repeatable, joined with `&`,
curl's own behavior for repeats), `-u`/`--user` (→ a real base64-encoded
`Authorization: Basic` header), `-b`/`--cookie`, `-A`/`--user-agent`,
`-e`/`--referer`, `--url`, and drops flags with no meaning for a request
this plugin sends itself (`-s`, `-v`, `-L`, `-o`, `--compressed`, timeouts,
TLS material, …) without ever mistaking one's value for the URL. Any
`-d`/`--data` present with no explicit `-X` implies `POST`, mirroring
real curl's own default rather than leaving a `GET` with a body for the
reader to notice was wrong.

```vim
:RA export
```

The reverse: parses whichever `###` block the cursor is in (the identical
resolution `:RA send` uses) and yanks a shareable `curl` command line to
the unnamed register — the same register convention `:RA yank` already
uses for a response body. Multi-line, headers sorted, single quotes
escaped with the standard POSIX `'\''` trick (deliberately not
`vim.fn.shellescape`, which would escape for Neovim's own `&shell` —
cmd.exe/PowerShell syntax on Windows — the wrong grammar for a `curl`
command meant to be pasted into any real shell or shared verbatim in a
doc).

**`:RA export` never resolves `{{var}}` placeholders** — the identical
trap `:RA env`'s own section above names, closed the identical way. It is
handed the raw, unresolved request straight from `runtime-analysis.parse`,
the same one `:RA history` and the "sending ..." placeholder already keep
unresolved. Exporting is sharing, and a `{{token}}` must render as
`{{token}}` there too, never the value it would resolve to.

### Why `:RARequest`/`:RASend` exist as separate flat commands, not only `:RA request`/`:RA send`

`:RA`, built via `lib.nvim.usercmd.composer`, is the verb-first shape
`NEW_PROJECT.md`'s own checklist prefers and every sibling plugin
(`:DocMap`, `:MDView`, `:Replace`) already uses. But `:RARequest`/`:RASend`
predate `:RA` and are this plugin's most-referenced public surface; keeping
both costs four lines in
[`bindings/usrcmds.lua`](../lua/runtime-analysis/bindings/usrcmds.lua) and
means a user's own keymap to either flat name never breaks on a rename.
Both call exactly the same handlers — there is no behavioral difference to
document twice.

## `:RATelemetry [subcommand] [namespace]`

Opt-in call counting and usage statistics for any Lua/Neovim plugin. A
second, separate compound command rather than `:RA telemetry ...` — see
"Why `:RATelemetry` is not `:RA telemetry ...`" below for the reasoning.
Registered by the same `setup()` call as `:RA` above, but its own module
(`runtime-analysis.telemetry`) registers nothing on `require` alone —
see that module's own extensive README
([`lua/runtime-analysis/telemetry/README.md`](../lua/runtime-analysis/telemetry/README.md))
for the full API this command is a thin front-end over: instances, scoping
(`wrap`/`wrap_loaded`/`wrap_fn`), the lifecycle (`start`/`stop`/`unwrap`),
persistent enable/disable, argument profiling, report metadata, and the
mdview browser bridge.

Subcommand table: [`docs/BINDINGS.md`](BINDINGS.md#ratelemetry-subcommands).

**Only a genuinely empty or recognized argument acts.** An unknown
subcommand reports what it expected rather than falling through to a
default — the same rule documentation.nvim's `:DocMap` follows for the
identical reason: a typo silently doing the wrong thing (rewriting a report,
resetting data) is worse than a typo doing nothing.

**Reading a namespace does not need `:RATelemetry`, or Neovim's UI, at
all** — [`scripts/telemetry.lua`](../scripts/telemetry.lua) is a headless
CLI counterpart: `nvim --headless -l scripts/telemetry.lua report
<namespace>` / `export <namespace> <path>`, built on the same
`telemetry.load()` a live instance never had to exist for. Not a
usercommand (see "What is not a command" below) — a separate entry point,
for CI, a cron job, or "what did last week look like" without opening the
editor.

---

## Why `:RATelemetry` is not `:RA telemetry ...`

One verb per plugin is the default `NEW_PROJECT.md`'s checklist prefers, but
not an absolute rule — the checklist itself names `replacer.nvim`'s
`:Replace` + `:Surround` split as a documented exception when a second
concern doesn't belong under the first verb. Telemetry is that case here:
it is a large, independent surface (11 subcommands, namespace completion,
its own extensive README) about a plugin's *runtime history* in general,
not specifically about the request runner `:RA` is named for. Nesting it as
`:RA telemetry start markdown.nvim` buries a namespace argument three
levels deep for no real gain, and documentation.nvim already established
the precedent this mirrors: `:DocMap` and `:DocBrowse` are two commands,
not `:DocMap browse ...`, split along the same "does something" vs.
"reports on something" line used here.

## What is not a command

- **No keymaps, no autocommands.** See [`docs/BINDINGS.md`](BINDINGS.md) —
  every entry point here is one of the four commands above.
- **`M.open_request`/`M.setup` are Lua API, not commands.** Documented in
  [`lua/runtime-analysis/init.lua`](../lua/runtime-analysis/init.lua)'s own
  module doc-comment and in `docs/IDEAS.md` §1 as the integration surface
  another plugin calls into directly.
- **`scripts/telemetry.lua` is a headless CLI script, not a usercommand.**
  It runs *instead of* a Neovim session with this plugin's `setup()`
  loaded, not alongside one — see the note under `:RATelemetry` above.
