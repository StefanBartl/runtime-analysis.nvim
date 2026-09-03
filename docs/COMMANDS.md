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
the whole buffer, never a picker** — the answer the roadmap
already settled before this was built.

This is also what makes a **real, committed `.http` or `.rest` file** work
with no new command at all: open one directly with `:e requests.http` (or
`.rest` — see `ftdetect/runtime-analysis.lua`, since Neovim only resolves
`*.http` to the `http` filetype natively, not `*.rest`) and `:RA send`
already reads "the current buffer", origin-agnostic — a scratch buffer
from `:RA request` and a real file opened by hand hit the identical code
path.

## GraphQL and multipart request bodies

the roadmap, named "for completeness" and shipped once a real
need existed: two request-body shapes beyond plain JSON/text, both VS
Code REST Client's own conventions rather than invented here — the same
"match an existing tool, don't design a third shape" posture the whole
request-buffer grammar has had since the very first version.

### GraphQL

```http
POST https://api.example.com/graphql
X-Request-Type: GraphQL
Content-Type: application/json

query GetUser($id: ID!) {
  user(id: $id) { name }
}

{"id": "42"}
```

`X-Request-Type: GraphQL` marks the body as GraphQL — the query text,
optionally followed by a blank line and a JSON variables object (REST
Client's own rule: "you need to add a blank line between GraphQL query
and variables if you need it"). `runtime-analysis.graphql.resolve` turns
this into the real payload a GraphQL server actually expects,
`{"query": "...", "variables": {...}}`, and strips the
`X-Request-Type` header — a directive consumed here, never forwarded to
the server, the identical pattern `parse.lua`'s own `Auth:` shorthand
already establishes for `Authorization`. No query at all with a
variables block that is not valid JSON is a real, named error, not a
silently empty `variables: {}`.

Runs **after** `{{var}}` resolution, not before —
so a placeholder inside the query or the variables block resolves the
ordinary way first, indistinguishable from a token typed there directly.
`:RA export` applies the same transform (a shared curl command should
still be valid GraphQL POST syntax) but never `{{var}}` resolution, the
same "exporting is sharing" rule every other export path already keeps.

### Multipart/form-data

```http
POST https://api.example.com/upload
Content-Type: multipart/form-data; boundary=----WebKitFormBoundary7MA4YWxkTrZu0gW

------WebKitFormBoundary7MA4YWxkTrZu0gW
Content-Disposition: form-data; name="title"

My title
------WebKitFormBoundary7MA4YWxkTrZu0gW
Content-Disposition: form-data; name="file"; filename="1.png"
Content-Type: image/png

< ./1.png
------WebKitFormBoundary7MA4YWxkTrZu0gW--
```

A `Content-Type: multipart/form-data; boundary=...` header plus a body
shaped like this — one `Content-Disposition: form-data; name="..."` part
per field, boundary-delimited. A part whose entire content is a single
`< ./relative/path` line means "read this local file's real bytes as the
part body", resolved relative to the request buffer's own directory when
it has one (a real, committed `.http`/`.rest` file), or the cwd otherwise
(an ad-hoc `:RA request` scratch buffer has no file to be relative to).
`runtime-analysis.multipart.resolve` reads the file and substitutes its
bytes in place of the `< path` line — the boundary structure itself is
left exactly as written, only file references are ever touched.

**`:RA export` never inlines file bytes.** A binary file's raw content is
not safe, shareable shell text (a stray `'`, a null byte — anything), so
`runtime-analysis.multipart.to_curl_flags` turns each part into curl's
own `-F "field=@path"` shape instead: curl reads the file itself when the
exported command actually runs, and the path is kept exactly as written
rather than resolved to this machine's own absolute path — a shared
command is portable precisely because it does not bake that in. A
malformed multipart body (`Content-Type` with no `boundary=`) falls back
to `--data-raw` with the literal, unresolved text on export — degraded,
but an honest export beats a silently dropped body.

**The one stated limit:** line endings. Both directions only ever join
with `\n`, the request buffer's own line ending, not RFC 2046's required
CRLF. Every server actually tested against accepts bare `\n` in
practice — real multipart parsers are lenient about it — but a
hypothetical strict one is not handled.

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
at `history_max_entries` (default 200) total, oldest dropped first, the same
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

Clears the current project's history outright. No confirmation prompt, no
backup offer — unlike `:RATelemetry reset`'s conditional "back up first?"
prompt (only shown when there is telemetry data to lose), this data is
disposable and locally-scoped enough that neither a confirmation dialog nor
a backup step meaningfully protects anything worth the friction.

## `:RA env [name]`

`{{name}}` inside a request buffer's url, header values or body — `{{baseUrl}}/users/:id`
— resolves against a *named* environment (`dev`/`staging`/`prod`, or any
name a project.s own files define). With an argument,
selects that environment directly (or reports the available names if it
doesn't exist, rather than silently doing nothing); with none, offers every
defined name via `vim.ui.select`, the same picker `:RA history` already
uses. **Session-scoped, not persisted across restarts** — which environment
you meant is a fact about the current editing session, not one worth
writing to disk.

### Where names and values come from

Two per-project JSON files at the project root — the same split IntelliJ's
HTTP Client already uses for exactly this problem, matched rather than
invented (the same reasoning the "Deliberately not: owning
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

a smoke-test shape for a local API, deliberately
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

paste a `curl` command line, get a request buffer;
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

## `:RA provenance <path>`

"who wrapped this function," the narrow slice of
`:RA inspect` (§5.1, below) worth shipping on its own first.

```vim
:RA provenance vim.notify
:RA provenance lib.nvim.notify.create
```

`path` is a dotted string — a `:RA`-style command can only ever take a
string, never a live table reference. Resolution tries a global-table walk
first (the `vim.*` shape), then `require()` of the whole prefix (the
`lib.nvim`-style module-field shape), and stops there: it does not guess
where a module boundary sits inside a longer path, the same "a wrong guess
is worse than no answer" stance `:RA import`'s own unrecognized-`curl`-flag
handling already takes.

**`<Tab>` completes the path, one level at a time.** Type `vim.` and Tab
lists `vim`'s function and table fields; complete a table, type `.`, Tab
again. Both kinds are offered because a table is the way down to a function.

The completion resolves containers the way `inspect` does with one deliberate
exception: **it never calls `require`.** Completing `lib.nvim.` by requiring
every candidate would load modules -- running their top-level code, registering
their autocmds -- as a side effect of pressing Tab. So completion reads only
the global-table walk (pure indexing) and `package.loaded` (what `require` has
*already* returned). A module that has not been loaded yet therefore does not
appear; typing its path out by hand still works, because `inspect` does call
`require`.

**Three answers, and the output is explicit about which one it is giving:**

- **This plugin's own telemetry wrapper: exact.** `runtime-analysis.telemetry
  .registry` is the one shared wrap layer every instance goes through, so
  it genuinely knows every subscribing namespace by name.
- **`lib.nvim.system.proc_trace`: exact.** It wraps four *known* paths
  (`vim.fn.system`, `vim.fn.systemlist`, `vim.system`, `vim.fn.jobstart`)
  and publishes `is_active()`, so this is a fact rather than an inference —
  and the line names how to undo it.
- **Anyone else's wrapper — any of the many plugins that monkey-patch
  `vim.notify` — best-effort.** There is no registry for a third-party wrap,
  so the only honest signal is `debug.getinfo`'s own source location:
  *where* the function currently resolving there was actually defined, not
  *who* put it there or *when*. The caveat is printed **only** in this case,
  because a report that both names a wrapper and then says nothing is known
  about wrappers contradicts itself.

**No shared wrapper registry, and that was a decision rather than an
omission.** `docs/IDEAS.md` §4.1 proposed one in `lib.nvim` so every
instance of this technique could be named. It was declined: there is one
consumer of the answer, and the case that would justify a convention — a
third-party monkey-patch — is precisely the one a convention cannot reach,
since such a plugin has never heard of `lib.nvim`. The two wrappers this
ecosystem does control turned out to be answerable without it. See that
entry for what would reopen the question.

## `:RA startup start|watch|report|probe`

Finds what blocks Neovim's main loop during and after startup.

**What it does that `--startuptime` and `:profile` cannot.**
`--startuptime` stops at the first screen redraw and never sees a later
block. `:profile` instruments Vimscript and Lua calls and is blind to libuv
callbacks — which is exactly the filesystem, subprocesses and LSP handling.
Here a libuv timer measures its **own** lateness, so a stall shows up
whatever it came from.

```vim
:RA startup start     " watch for stalls, report after 12s
:RA startup watch     " keep measuring until you ask
:RA startup report    " stop and show the timeline
```

**The timeline puts everything on one clock:** plugin loads with lazy's load
time *and* load reason, `VimEnter`, `VeryLazy`, `LspAttach`, LSP progress.
The load reason is the part that cracks cases: `<- VeryLazy` means the spec
asked for it, `<- require '<mod>' from <file>` means another file defeated
the lazy loading — and only the second is a bug.

**`:RA startup probe` measures the startup itself.** The timer has to tick
*before* the config is sourced, which a lazily loaded plugin cannot arrange
for itself, so the probe is a `--cmd` line: it sets `package.path` from its
own location and needs neither the runtimepath nor a plugin manager. The
command prints and yanks the finished line.

**How not to read the numbers.** Startup timing scatters — runs of an
identical config vary by hundreds of milliseconds, mostly from filesystem
cache and, on Windows, the AV filter driver — so compare medians of three
runs rather than single numbers. And a stall is not always the plugin named
above it: a 40ms load time under a 300ms block means something else
contributed too. The report arrives as a notification and is written to
`ra-startup.log` in the current directory.

## `:RA inspect <module>`

"Runtime inspection — a second pillar." Walks a
live `package.loaded[module]` table and renders it: functions (upvalue
counts, source location), nested tables (their own shape), metatables,
and what a direct key *shadows* through `__index`. lib.nvim's own roadmap
turned this down as `:LibInspect` — "actually executing/requiring code is
a different trust model than docmap's pure static scan" — and named a
future tool as the right home; this is that tool.

```vim
:RA inspect runtime-analysis.telemetry
```

`<Tab>`-completes against `package.loaded`, live — whatever is actually
loaded in this session, not a list frozen at `setup()`.
`runtime-analysis.loaded` (§5.3) already answers the flat, one-level
question "what functions does this module have right now", the half
documentation.nvim's own `:DocBrowse` "loaded" mode joins against; this
answers the deeper one a config author actually needs — what a table
*contains*, after however many merge passes built it.

**Three open design questions inherited from lib.nvim's rejection,
resolved:**

- **Cycle and depth limits.** Cycle-*safety* comes from an identity-keyed
  `seen` set tracking the current ancestor chain — the same convention
  lib.nvim's own `lib.lua.tables.deep_copy` already uses — which alone
  guarantees termination on a table with a real cycle in it.
  `max_depth` (default 3) is a separate, purely cosmetic cap on top of
  that, for readability: enough to see through a config table after a
  few merge passes, not a correctness mechanism.
- **`__index` is reported, never called.** A direct key that would also
  resolve through a table `__index` is flagged as shadowing it — answered
  by comparing keys, no invocation needed. When `__index` is a function,
  only its presence is reported: calling it would be a real side effect
  on the code being inspected, the same "record it, don't guess it"
  trade-off `documentation.core.loaded_diff` and `endpoint_coverage.lua`
  already take elsewhere in this ecosystem.
- **Renders via the same float every other report in this plugin already
  uses** — `lib.nvim.ui.kit.viewer`, falling back to `vim.notify` when
  kit is unavailable, exactly like `:RATelemetry` and `:RA usage`.

## `:RA usage`, `:RA usage start`, `:RA usage stop`

which of your own keymaps and typed commands you
actually press. A different *product* from everything else `:RA` does —
instrumenting the editor rather than instrumenting code — and the first
feature in this plugin that records *what the person did* rather than
*what the code did*.

```vim
:RA usage start   " begin counting — nothing runs before this
:RA usage         " report current counts
:RA usage stop    " stop counting; collected counts stay readable
```

**Opt-in, local, and never grows a "share this" feature** — the exact
posture the roadmap entry itself demanded before naming the feature worth
building. `:RA usage start` wraps `vim.keymap.set` so every
function-callback mapping registered from that point on counts its own
presses, and installs a `CmdlineLeave` hook that counts a typed command by
name once it actually commits (an aborted, `<Esc>`-cancelled command line
records nothing). Built on `runtime-analysis.telemetry` itself — one real
instance underneath, the same `wrap_fn` mechanism §7.2's cost-vs-use report
already reads for code, pointed at editor input instead.

**Honest limits, not silently dropped cases.** Only mappings set *after*
`:RA usage start` are ever seen. A string-rhs mapping
(`vim.keymap.set('n', 'x', ':SomeCommand<CR>')`) has no function to wrap —
if the command it runs goes through `:`, the `CmdlineLeave` hook may still
count that, but the mapping that triggered it will not be. A buffer-local
mapping sharing the same mode+lhs as a different mapping elsewhere is
combined into one count, not tracked per buffer.

## `:RA loaded snapshot <prefix> [name]` and `:RA loaded snapshots <prefix>`

`docs/FEATURE_LOG.md` §5.4: persisted, named captures of
`runtime-analysis.loaded`'s live read, so it can be viewed later, or from a
process that never itself loaded the code in question —
documentation.nvim's `:DocMap serve` Loaded Analysis panel is the consumer
this was built for, since a browser tab answering `GET /api/loaded` has no
live `package.loaded` of its own to read and, unlike its Telemetry panel
counterpart, has no "latest" fallback to reach for instead.

```vim
:RA loaded snapshot documentation
:RA loaded snapshot documentation nightly
:RA loaded snapshots documentation
```

`:RA loaded snapshot <prefix> [name]` walks `package.loaded` for every key
equal to `prefix` or starting `prefix .` — the identical scoping
`wrap_loaded(prefix)` already uses, so the same prefix that instruments a
plugin also snapshots it — and saves `{ [module_id] = M.functions(module_id) }`
for every match under `name` (default: a timestamp). Warns rather than
erroring when nothing is loaded under `prefix` at all. **One identifier,
not two, unlike telemetry:** a telemetry namespace can genuinely differ
from the module prefix it wraps, but a loaded snapshot has nothing to name
except the prefix it was captured under, so there is no separate namespace
argument to keep in sync with it.

`:RA loaded snapshots <prefix>` lists every snapshot saved for `prefix`,
newest first — the same shape `:RATelemetry snapshots <ns>` already
returns. Storage deliberately parallels `telemetry/store.lua` (same
`lib.nvim.cache.disk` primitive, same retention/eviction policy — capped at
`loaded.SNAPSHOT_RETENTION`, 20, oldest evicted first) without reusing it
directly: a loaded snapshot is a module→function-keys map, not a
call-count aggregate, and the two concerns stay on separate cache-key
prefixes (`"loaded/"` vs. telemetry's own) so they never collide on disk.

Module: [`lua/runtime-analysis/loaded.lua`](../lua/runtime-analysis/loaded.lua)
(`M.snapshot`, `M.list_snapshots`, `M.load_snapshot`). Feature-level
overview: [`docs/FEATURES/LOADED.md`](FEATURES/LOADED.md).

### Why `:RARequest`/`:RASend` exist as separate flat commands, not only `:RA request`/`:RA send`

`:RA`, built via `lib.nvim.bindings.usercmd.composer`, is the verb-first shape
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
(`wrap`/`wrap_loaded`/`wrap_fn`), per-key table read/write counting
(`track_table`, explicit `get`/`set` functions rather than a table proxy —
see that README's own "Table tracking" section for why), the lifecycle
(`start`/`stop`/`unwrap`), persistent enable/disable, argument profiling,
report metadata, the mdview browser bridge, and the sortable/filterable
HTML dashboard (§4.4,
`report_style = "html"`).

Subcommand table: [`docs/BINDINGS.md`](BINDINGS.md#ratelemetry-subcommands).

`:RATelemetry status` is the whole-fleet view: one compact block per
namespace this plugin knows about — live this session or only ever
persisted on disk, so a plugin that recorded last week and simply has not
loaded yet this session still shows up — naming its state, its recording
mode and what is actually sitting on disk for it (size and path). Unlike
the bare `report` view (a full per-function breakdown for every live
instance at once), it stays a screenful regardless of how many namespaces
exist; `<CR>` on a row still opens that namespace's own full report, the
same drilldown the bare view offers.

**Keys on the `kit` report float** (`report`/`open` when `report_style`
resolves to `"kit"`, and the mdview/preview-tab fallback of `open` when
neither is actually loadable): `r` re-flushes and refreshes the view in
place, `<CR>` on a namespace's header row (`"<namespace>  —  <state>"`) drills
into that one namespace (bare "every instance" views only — a
single-namespace float's own header is already itself), `gO` writes and opens
this report's `report_style = "html"` rendering in the system browser
(`:RATelemetry open` only — `report` has no HTML path to write), `?` shows
the full cheatsheet for whichever of these the current view actually wired
up, `q`/`<Esc>` closes.

### Standalone `*All` aliases

`:RATelemetryStartAll`/`StopAll`/`ResetAll` are exactly `:RATelemetry
start`/`stop`/`reset` with no namespace (already "every live instance") —
they exist only because that bare form is reached for often enough to earn
a command name of its own.

`reset` (bare and `ResetAll` alike) asks the same single "back up first?"
question `:RATelemetrySetupAll` below already does, before dropping
anything: one prompt for a directory (created if it does not exist), shown
only if at least one live instance actually has data on disk or pending in
memory. Declining (`<Esc>`/empty input) aborts the reset entirely — nothing
is cleared. A namespace with nothing collected never triggers the prompt at
all (`:RATelemetry reset <ns>` on an empty instance just resets, silently).

`:RATelemetrySetupAll` / `:RATelemetrySetupAllFull` are the bare forms of
`:RATelemetry setup` / `:RATelemetry full` — they act on
`opts.telemetry.plugins` **and** `opts.telemetry.extra`, the same policy
tables `require("runtime-analysis").setup({telemetry = ...})` already
threads through `telemetry.lazy.setup()`. Pass a namespace to narrow either
one to a single target (`:RATelemetry full nvim-config`), which is also the
only way to select an `extra` target — a config has no repo to name it by.
For every target that is loaded right now:

1. If it has anything on disk already, back it up. One prompt for the
   whole run (a directory, created if it does not exist yet) — not one per
   plugin — appears only when at least one candidate actually has data;
   declining aborts the entire run rather than resetting some plugins'
   data without a backup.
2. `reset()` — drop the aggregate, in memory and on disk.
3. **Re-wrap.** Even a plugin already fully wrapped this session gets
   `wrap_loaded()`/`wrap()` called again — a no-op for anything already
   registered, but it is also what picks up a submodule the plugin required
   *after* its first wrap snapshot (the catch-up scan at startup, or its own
   `User LazyLoad` moment). A submodule loaded that way stays permanently
   unwrapped otherwise: zero calls, no argument data, not because
   `profile_args` was ever off but because nothing ever hooked that
   function. **This is the fix if some functions never show argument data
   while others from the same plugin do** — rerun `:RATelemetrySetupAll`
   (or `Full`) after using the feature whose module loaded late, and the
   newly-loaded functions join the wrap.
4. `start()` — `:RATelemetrySetupAll` uses each plugin's own already
   -configured `profile_args`/`timing` (for this config, `profile_args =
   true` by default — see `lua/config/telemetry.lua` in the personal Neovim
   config, not this repository); `:RATelemetrySetupAllFull` forces both on
   for every plugin regardless of its individual policy, the `setup_all`
   equivalent of `:DocMap full`'s LuaLS enrichment — more expensive,
   invoked on request rather than left on by default.

Only targets currently *loaded* are candidates — nothing here can wrap a
module that has not `require`d yet; a not-yet-loaded plugin is still picked
up the normal way (`telemetry.lazy`'s own `User LazyLoad` autocmd) once it
does load. `lib.nvim`'s own telemetry aggregate (`opts.telemetry.lib_nvim`)
is deliberately out of scope — it wraps through
`lib.strategies.telemetry_wrap`, a different mechanism than the
`wrap_loaded()` re-scan every other candidate here goes through.

### Instrumenting your own Neovim config (`opts.telemetry.extra`)

`opts.telemetry.plugins` can only describe what a plugin manager resolves.
Your own config is not one of those things — it has no repo, no spec, and
usually several unrelated root prefixes rather than one `main` — yet it is
often the most interesting Lua tree in the session, and the only one whose
dead code nobody else will ever report on. `extra` is that target, stated
outright:

```lua
require("runtime-analysis").setup({
  telemetry = {
    extra = {
      {
        namespace = "nvim-config",
        -- your config's own top-level lua/ directories
        mains = { "config", "bindings", "plugins", "autocmds", "lsp" },
        profile_args = true,
      },
    },
  },
})
```

That is the whole setup. `nvim-config` then behaves as an ordinary
namespace everywhere: `:RATelemetry nvim-config`, `coverage`, `compare`,
`snapshot`, `export`, the HTML dashboard, and
`:RATelemetry setup|full nvim-config`.

**It works without lazy.nvim.** `extra` resolves purely through
`package.loaded`; the lazy.nvim adapter covers `plugins` only.

**Wrapping is deferred to VimEnter by default, and that default matters.**
When `runtime-analysis.setup()` runs it is usually still *inside*
`lazy.setup()`, before your config's later phases (options, autocmds, LSP,
keymaps) have required anything — and `wrap_loaded()` only ever sees what
is already in `package.loaded`. Wrapping at that moment would produce a
nearly empty namespace. `wrap_at` overrides it per target:

| `wrap_at`   | when                                                      |
| ----------- | --------------------------------------------------------- |
| `"VimEnter"` | default — VimEnter + `vim.schedule`, once the UI is up    |
| `"setup"`    | immediately, only right for an already-loaded target      |
| `"manual"`   | never automatically; `:RATelemetry setup\|full <ns>` only |

**The same blind spot every wrap has:** a module first required *after* the
wrap ran (a keymap handler pulled in on first press) stays unwrapped until
something re-wraps. `:RATelemetry setup <ns>` is that something, callable
any time — see point 3 above.

Per-target options: `mains` (required), `namespace` (required), `deep`
(default **true** here, unlike a plugin's façade-first default),
`profile_args`, `timing`, `persist`, `dir`, `wrap_at`.

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

- **No keymaps, and no user-facing autocommands.** See
  [`docs/BINDINGS.md`](BINDINGS.md) — every entry point here is one of the
  commands above. The handful of real registrations that do exist are opt-in
  plumbing behind telemetry and usage tracking, listed there; nothing watches
  buffer or window events.
- **`M.open_request`/`M.setup` are Lua API, not commands.** Documented in
  [`lua/runtime-analysis/init.lua`](../lua/runtime-analysis/init.lua)'s own
  module doc-comment and in `docs/IDEAS.md` §1 as the integration surface
  another plugin calls into directly.
- **`scripts/telemetry.lua` is a headless CLI script, not a usercommand.**
  It runs *instead of* a Neovim session with this plugin's `setup()`
  loaded, not alongside one — see the note under `:RATelemetry` above.
