# runtime-analysis.nvim — roadmap

A brainstormed backlog, grouped by theme. **Nothing here is scheduled**, and
several entries end in "probably not" — a documented rejection is as much a
result as a shipped feature, and worth keeping so the question does not get
re-litigated from a blank slate.

What is already built is in [the README](../README.md) and, for telemetry
specifically, in
[`lua/runtime-analysis/telemetry/README.md`](../lua/runtime-analysis/telemetry/README.md).
The architectural split this plugin exists inside — static truth in
documentation.nvim, runtime truth here — is
[`documentation.nvim/docs/ECOSYSTEM.md`](https://github.com/StefanBartl/documentation.nvim/blob/main/docs/ECOSYSTEM.md);
its sequencing section is the closest thing to a committed plan either
plugin has, and step 8 there (a telemetry mode in `:DocBrowse`) is the one
item below that is genuinely next rather than speculative.

**The thesis this backlog is filtered against:** does the feature answer a
question that can only be answered *by running the code*? Anything a static
scan could answer belongs in documentation.nvim instead, and several
otherwise-attractive ideas are turned down below on exactly that ground.

---

## Phases

Every item below already lives in the themed sections that follow this one;
this is a second cut across the same material, sorted by how much real work
sits between here and shipping. **Not a schedule** — nothing here has a date
attached — a triage the themed sections do not attempt on their own, the
same kind of overlay `docs/IDEAS.md` §6 uses for its own five-item shortlist.

**How an item lands in a bucket:**

| Phase | Criterion |
| --- | --- |
| **Quick win** | Hours, not days. Every primitive it needs already exists in this repo or lib.nvim; no open design question; no dependency on another repository's own work. |
| **Medium** | Multi-day. Either a real decision has to be made first (a schema, a security trade-off, an open question the section names explicitly), or it touches several files or a small state machine — but the shape and the cost are both known. |
| **Long-term** | Blocked on something this document itself already says is unmeasured or unresolved: an unmeasured `debug.getinfo` cost, several open design questions, another repository's half of the work, or a section the document itself calls speculative. |

### Quick wins

| Item | Note |
| --- | --- |
| §1.4 `.http`/`.rest` file support | "Mostly free" per its own text, but sequenced after §1.2 — needs `###` splitting to exist first |
| §2.2 A response pane worth reading | JSON pretty-printing + a filetype, no new renderer |
| §2.4 Auth helpers | Bearer/Basic as one line; OAuth *flows* explicitly excluded |
| §4.1 A CLI / headless entry point | "A script and an argument parser, not new analysis" — `telemetry.load()` already does the reading half |
| §6.1 Mode 8 — telemetry in `:DocBrowse` | Both halves this repo owns (`telemetry.load()`, `Data.modules`, `resolved_modules()`) already ship; what remains is documentation.nvim's entry builder, not work here |
| `:checkhealth runtime-analysis` | **Done (2026-08-03)** — see Housekeeping below |
| Vimdoc (`doc/runtime-analysis.txt`) | **Done (2026-08-03)** — see Housekeeping below |
| `docs/COMMANDS.md` + `docs/BINDINGS.md` | **Done (2026-08-03)** — see Housekeeping below |
| `config/init.lua` + `config/DEFAULTS.lua` + `bindings/usrcmds.lua` + a top-level `@types/init.lua` | **Done (2026-08-03)** — see Housekeeping below |
| Compound `:RA [subcommand]` usercommand | **Done (2026-08-03)** — see Housekeeping below |

### Medium

| Item | Note |
| --- | --- |
| §1.1 Async sending | "Do this one first" among the request-runner gaps; view + pending state + cancel path — primitives (`fetch_raw`, `lib.nvim.progress`) already exist |
| §1.2 Multiple requests per buffer (`###`) | Splitter + "which request is under the cursor" + a picker-or-not decision |
| §1.3 Request history | `cache.disk`-backed; one open question to settle first — request-only vs. response bodies too — before writing any of it |
| §2.1 Variables and environments | The feature that makes a request collection shareable; the security trap (tokens ending up in an env file) has to be designed in from the start, not added after |
| §2.3 curl import / export | Import is both the more valuable half and the harder one — real argument parsing, not templating |
| §2.5 Response assertions | Keep it to "is this endpoint still 200", not a general assertion language |
| §3.2 Sampling | Mechanically straightforward; the honest-limits wording ("a sampled count is an estimate") has to ship in the same commit |
| §3.3 Startup attribution | The lazy adapter already knows exactly when each plugin loads — half the mechanism exists |
| §3.4 Error and failure fingerprinting | Reuses the existing argument-fingerprint machinery, pointed at errors instead of arguments |
| §4.2 Comparison across time windows | Day buckets are already stored; this is a report mode, not a collection change |
| §5.2 Wrapper provenance | The narrow, high-value slice of §5.1 worth shipping first; the telemetry registry already knows its own wrappers |
| §6.2 Endpoint coverage | Needs §1.3 (request history) first, plus a join key |
| §6.3 Documentation priority by real usage | Needs §6.1's mechanism to exist first |
| §7.1 Keymap and command usage | Mechanically the existing wrap machinery pointed at `vim.keymap.set` plus a `CmdlineLeave` hook; stays local and opt-in, never grows a "share this" feature |
| §7.2 Plugin cost-versus-use | Combines §3.3 with call counts already collected |
| Test coverage for the request runner's real transport | `runner.lua` is only exercised against a real transport at the lib.nvim end today |
| `scripts/gen_map.lua` + documentation.nvim as a dev dependency | A real CI gate (checkout, generate, byte-compare), not a documentation update — see Housekeeping below for why it was not attempted alongside the smaller items in this pass |

### Long-term / speculative

| Item | Note |
| --- | --- |
| §2.6 GraphQL / multipart / file upload | "Neither is a priority without a concrete need" |
| §3.1 Call trees | The single biggest capability gap in the whole document, but explicitly gated on measuring `debug.getinfo`'s real cost first — do not build before that number exists |
| §4.3 Standard trace formats | Meaningless before §3.1 (call trees) exists — nothing to export yet |
| §4.4 A real dashboard rather than a report | Gated on the browser-tier decision `docs/IDEAS.md` §3.1 says to make *before* building anything, so a third pipeline does not get built by accident |
| §5.1 `:RAInspect <module>` | Three open design questions, inherited unanswered from lib.nvim's own rejection of this exact idea |
| §5.3 Diff loaded-vs-declared | The sharpest join in this document, and it needs both plugins' cooperation, not only this repository's own work |
| §7.3 LSP request latency | Explicitly low priority; territory other tools already cover well |

### Rejected outright — not phased

§3.5 (a general profiler) and everything in "Deliberately not building" at
the end of this document are not on any timeline at all. A documented
rejection is not a phase with an infinite delay attached to it; it is a
closed question, kept here so it does not get re-opened from a blank slate.

---

## 1. HTTP request runner — the stated gaps

The README already names four. They are listed first because they are the
cheapest real work in this document and the most likely to be missed while
using it.

### 1.1 Async sending

`:RASend` blocks until the response arrives. Fine for a request bounded in
milliseconds, genuinely bad for a slow endpoint — the editor is frozen with
no way to cancel. `lib.nvim.net.curl` already has a non-blocking
`fetch_raw` alongside the `fetch_raw_blocking` this uses; the work is in the
*view*, not the transport: a pending state, a spinner
(`lib.nvim.progress` already exists), and a cancel path.

**Do this one first.** It is the only entry in this whole document that
fixes something actively unpleasant rather than adding something missing.

### 1.2 Multiple requests per buffer (`###`)

Both sibling tools (VS Code REST Client, IntelliJ HTTP Client) separate
requests in one file with a `###` line, and a real `.http` file collected
over a project is a *file of requests*, not one. `parse.lua`'s doc-comment
already flags this as deliberately not attempted.

Needs: a splitter, a "which request is the cursor in" resolution, and a
decision about whether `:RASend` sends the one under the cursor (yes,
almost certainly) or offers a picker.

### 1.3 Request history

Nothing is saved between sends. The obvious shape is
`lib.nvim.cache.disk`-backed, per-project (`lib.nvim.fs.project_key`
already computes that key), listing method/URL/status/timestamp, with
"reopen this as a buffer" as the one interaction that matters.

**Open question worth deciding before building:** does history store the
*request* only, or the response too? Responses can be large and can contain
secrets from a real API. Request-only is the safe default; response bodies
behind an explicit opt-in, if at all.

### 1.4 `.http` / `.rest` file support

Today a request lives in a scratch buffer. Recognizing a real `.http` file
on disk — so a project can commit its request collection — is mostly free:
the filetype already resolves to `http`, and `:RASend` already reads the
current buffer. What it needs is `###` (1.2) first, since a committed file
is exactly the case that holds several requests.

---

## 2. Request ergonomics

Everything here is "the runner is used daily now" work. Do none of it until
§1 is done and the thing is actually being used.

### 2.1 Variables and environments

`{{baseUrl}}/users/:id`, resolved from a per-project environment file, with
`dev`/`staging`/`prod` as named sets. This is the single feature that
separates "I can send a request" from "I keep my requests in this repo" —
without it, every committed request hardcodes a host and is wrong for
everyone else.

**The trap, stated up front:** an environment file is where API tokens end
up. It must be gitignore-able by default and must never be echoed into the
response pane or a log. A `{{token}}` that renders as `{{token}}` in
history and as its real value only in the actual request is the design to
aim for.

### 2.2 A response pane worth reading

Today it is status + headers + body as plain lines. Worth having: JSON
pretty-printing and folding (`vim.json.decode` + a filetype, not a new
renderer), syntax highlighting per content-type, and a way to yank just the
body. Cheap, and it compounds with everything else in this section.

### 2.3 curl import / export

Paste a `curl` command line, get a request buffer; the reverse for sharing.
Every API's documentation and every browser's "copy as cURL" produces
exactly this, so import is the higher-value half by a lot.

### 2.4 Auth helpers

Bearer/Basic as one line rather than a hand-written header. Small, and
mostly a shorthand — but OAuth *flows* (redirect, token refresh) are a
different scale of problem entirely and should not be attempted here.

### 2.5 Response assertions

`# @expect status 200` style comments, checked after a send, failures into
the quickfix list. Turns the runner into a smoke-test tool for a local API.

**Reasonable, but note what it competes with**: this is the point where a
request runner starts becoming a test framework, and there are good
dedicated ones. Worth doing only in the narrow "I just changed this
endpoint, is it still 200" shape, not as a general assertion language.

### 2.6 GraphQL / multipart / file upload

Named for completeness. GraphQL is mostly "a POST with a specific body
shape" and is cheap once §2.1 exists; multipart file upload is a real
`curl` argument-construction problem and much less so. Neither is a
priority without a concrete need.

---

## 3. Telemetry — what gets collected

The module counts calls, times them, fingerprints arguments and bounds its
own cardinality. Everything below is about the *shape* of what it records,
not about reading it (that is §4).

### 3.1 Call trees, not just counts

The single biggest capability gap. Today the answer is "`fs.read` was called
4 812 times"; the question that usually follows is "**by whom**", and the
data cannot answer it. Recording the immediate caller (one frame of
`debug.getinfo`, at wrap time) would turn a flat count into a call graph —
and it is the exact data documentation.nvim's static `calls` extraction
guesses at, which makes the join in §6 far stronger.

**Cost is the whole question.** `debug.getinfo` per call is not free, and
this module's headline property is that counting costs 0.014 µs. This has
to be opt-in per instance, measured before it ships, and honest in the
README about what it costs — the same treatment `profile_args` already got.

### 3.2 Sampling

The complement to §3.1: instead of recording every call, record every Nth,
or every call during a sampled window. Makes expensive collection modes
(timing, argument profiling, call trees) affordable on a hot surface.
Straightforward to implement, and the honest limits section has to say
plainly that a sampled count is an estimate.

### 3.3 Startup attribution

Which plugin's `config()` cost what, as a waterfall. lazy.nvim already
reports its own numbers, so the value here is specifically *within* a
plugin — which of its modules the startup cost actually sits in. The lazy
adapter (`telemetry.lazy`) already knows exactly when each plugin loads,
which is half the mechanism.

### 3.4 Error and failure counting as a first-class axis

`errors` exists but is a per-function counter. Recording *what* the error
was (fingerprinted like arguments already are, bounded the same way) would
make "this function fails 3% of the time, always with the same message" a
readable fact.

### 3.5 Deliberately not: a general profiler

Neovim has `:profile`, and LuaJIT has its own profiler. This module's whole
premise is that it is *installed*, cheap and left running for a week — a
different instrument from one you switch on for thirty seconds to find a
hot loop. Competing with them would cost the property that makes this
useful. **Revisit if:** never, realistically. The right move if someone
needs a real profiler is to point at the real profiler.

---

## 4. Telemetry — reading it

### 4.1 A CLI / headless entry point

`nvim --headless -l scripts/telemetry.lua report lib.nvim` — read a
namespace off disk with no editor session. `telemetry.load()` already does
the reading part with no live instance required, so this is a script and an
argument parser, not new analysis. Useful for CI, for a cron job, and for
"what did last week look like" without opening the editor.

### 4.2 Comparison across time windows

`report({ since = "7d" })` exists; "this week versus last week" does not.
Day buckets are already stored, so the data is there — this is a report
mode, not a collection change. The interesting output is *what changed*:
newly-hot functions, functions that went cold, not two tables side by side.

### 4.3 Standard trace formats

Export to a format an existing viewer already opens — speedscope's JSON, or
the Chrome trace format. Only meaningful once §3.1 (call trees) exists;
before that there is no tree to view, and a bar chart of counts is
something the Markdown report already does adequately.

### 4.4 A real dashboard rather than a report

The mdview bridge renders a Markdown document that happens to update. A
purpose-built HTML view (sortable, filterable, the way
documentation.nvim's Analysis tab is) would be better — and is exactly the
kind of thing that should be *stolen* from documentation.nvim's renderer
rather than written twice. Worth doing only if the Markdown report is
actually being read often enough to feel limiting.

---

## 5. Runtime inspection — a second pillar

Currently the plugin has one collection mechanism (wrapping) and one I/O
tool (the request runner). This is the missing third thing, and it is the
most on-thesis idea in this document: **inspect what is actually loaded,
right now.**

lib.nvim's own roadmap turned this down as `:LibInspect` with a precise
reason — "actually executing/requiring code is a different trust model than
docmap's pure static scan" — and named a future tool as the right home.
**This is that tool.** Executing and inspecting live state is not a foreign
concern here; it is the entire premise.

### 5.1 `:RAInspect <module>`

Walk a live `package.loaded` table and render it: functions, their upvalue
counts, tables and their shapes, metatables, what is shadowed. The
questions it answers that no static scan can: *is this module even loaded*,
*is this function the one the source declares or has something wrapped it*,
*what does this config table actually contain after three merge passes*.

lib.nvim's rejection listed three open design questions that are still the
right ones and are still unanswered:

1. Cycle and depth limits when walking a live table.
2. Whether to call into `__index` functions or just report that they exist.
   (Calling has side effects; reporting is honest but less useful.)
3. Where the result renders — `lib.nvim.ui.kit` float, a scratch buffer, or
   something else.

### 5.2 Wrapper provenance

A narrow, high-value slice of §5.1 that should probably ship first: given a
function, say *who wrapped it*. Between this plugin's own telemetry,
`lib.nvim.system.proc_trace`, and any number of plugins that monkey-patch
`vim.notify`, a Neovim session accumulates wrappers, and "why is this
function not the one in the source" is a genuinely hard question today. The
telemetry registry already knows its own wrappers; the rest would be
best-effort.

### 5.3 Diff loaded-vs-declared

The sharpest form of the static × runtime join, and it needs both plugins:
documentation.nvim knows every function the source declares; this plugin
can enumerate what is actually on the loaded table. The difference in
either direction is interesting — declared but never loaded (dead file? or
lazy?), loaded but not declared (generated? wrapped? a typo'd key?).

---

## 6. The static × runtime join

The reason two plugins exist. `documentation.nvim/docs/ECOSYSTEM.md` §7 has
the full argument; these are the concrete pieces.

### 6.1 Mode 8 — telemetry in `:DocBrowse`

**The one genuinely-next item in this document.** Already designed, in
detail, in
[`lib.nvim/docs/ROADMAP/telemetry-documentation-bridge.md`](https://github.com/StefanBartl/lib.nvim/blob/main/docs/ROADMAP/telemetry-documentation-bridge.md):
cross static "no caller found" against runtime "actually called", and the
four cells of that table are each a different, actionable claim. The
`dead-function` false-positive suppression is the half that pays for
itself immediately.

Both halves of the contract already ship: `telemetry.load()` reads a
namespace with no live instance, and `Data.modules`/`resolved_modules()`
answer "which key is which real module". What is left is entirely on
documentation.nvim's side — an entry builder and a branch, per its own
`MODES` architecture.

### 6.2 Endpoint coverage

documentation.nvim knows every route the source declares (`core/endpoints.lua`);
this plugin's request runner knows which ones were actually sent. "Three of
your eleven routes have never been exercised" is a real answer neither can
give alone, and it needs no new collection — only request history (§1.3)
and a join key.

### 6.3 Documentation priority by real usage

Weight documentation.nvim's undocumented-function list by call count.
"Undocumented, alphabetically" is a list nobody works through;
"undocumented and called 4 000 times this week" is a queue. Named in the
bridge document as one of its two aggregate lines and still unbuilt.

---

## 7. Editor and session analytics

Speculative, and grouped separately because it is a different *product*
than everything above — instrumenting the editor rather than instrumenting
code.

### 7.1 Keymap and command usage

Which of your mappings you actually press. The honest use case is pruning:
a config accumulates bindings for years and nothing ever tells you which
ones went cold. Mechanically it is the existing wrap machinery pointed at
`vim.keymap.set`'s callbacks plus a `CmdlineLeave` hook.

**The one real caveat:** this is the first thing in this plugin that would
record *what the person did* rather than *what the code did*. It stays
local, it stays opt-in, and it should never grow a "share this" feature.

### 7.2 Plugin cost-versus-use

Combine startup attribution (§3.3) with per-plugin call counts (already
collected) into one number: what each plugin costs at startup versus how
much you actually use it. That is the report that gets plugins deleted, and
nothing else in either plugin produces it.

### 7.3 LSP request latency

Which server is slow, on which request kind. Plausible and useful; also
squarely in territory other tools cover, and it would mean tracking
Neovim's LSP client internals across releases. Low priority.

---

## 8. Housekeeping

Not features, but the gap between "works on this machine" and "a plugin
someone else can install". Prompted by going through
[`NEW_PROJECT.md`](https://github.com/StefanBartl/Notes/blob/master/MyNotes/Checklists/Lua/NEW_PROJECT.md)'s
own checklist against this repository (2026-08-03) — the items below are
exactly what that pass found missing, revisited a second time the same day
once the compound-usercommand item's original verdict turned out to be
wrong (see that item's own note below).

- ~~**`:checkhealth runtime-analysis`** — is `curl` present, is `lib.nvim`
  the version this expects, is the telemetry cache directory writable, is
  mdview available for `report_style = "auto"`.~~ **Done (2026-08-03)** —
  [`lua/runtime-analysis/health.lua`](../lua/runtime-analysis/health.lua),
  modeled on documentation.nvim's own `editor/health.lua`: reports resolved
  configuration (live telemetry instances, persistently disabled namespaces,
  the cache directory and whether it is writable) rather than only
  presence/absence.
- ~~**Vimdoc** (`doc/runtime-analysis.txt`). Both sibling plugins have one;
  this has a README and nothing `:help` can find.~~ **Done (2026-08-03)** —
  [`doc/runtime-analysis.txt`](../doc/runtime-analysis.txt), `doc/tags`
  gitignored (generated by `:helptags`, not committed — the same convention
  documentation.nvim and mdview.nvim both already use).
- **Test coverage for the request runner's real transport.** `runner.lua`
  is currently exercised against `lib.nvim.net.curl`'s own hermetic
  `vim.uv` TCP server test at the lib.nvim end, not here. **Still open** —
  see the Medium phase above.
- ~~**A `docs/COMMANDS.md`**, once there are more than three commands.
  documentation.nvim's is the model.~~ **Done (2026-08-03)** —
  [`docs/COMMANDS.md`](COMMANDS.md); [`docs/BINDINGS.md`](BINDINGS.md) also
  added in the same pass (required by `NEW_PROJECT.md`'s own checklist, and
  had not existed at all before this).
- **`scripts/gen_map.lua` + documentation.nvim as a dev dependency.**
  `NEW_PROJECT.md` §4 requires this (a byte-comparison `--check` gate in CI,
  the same one documentation.nvim and mdview.nvim both already run). **Not
  done** — a real, separate piece of work (a new CI job, a committed
  artifact, a new gate to keep green), not a documentation update, and
  deliberately not attempted alongside the smaller items above. Belongs in
  the Medium phase, not Quick wins.
- ~~**A compound `:RA [subcommand]` usercommand**, per `NEW_PROJECT.md` §5's
  own preferred shape.~~ **Done (2026-08-03)** —
  [`lua/runtime-analysis/bindings/usrcmds.lua`](../lua/runtime-analysis/bindings/usrcmds.lua),
  built on `lib.nvim.usercmd.composer` (the same module `:DocMap`/`:MDView`
  use), `:RA request` / `:RA send`, `<Tab>`-completed. Revised from this
  section's own earlier "deliberately not done" verdict: the original
  worry — that renaming `:RARequest`/`:RASend` would break a user's own
  keymap to either name — turned out not to force a choice at all.
  `:RARequest`/`:RASend` stay registered verbatim as flat aliases calling
  the exact same handlers `:RA`'s routes do; nothing was renamed, only
  added to. `:RATelemetry` stays a separate second compound command rather
  than folding under `:RA telemetry ...` — see `docs/COMMANDS.md`'s own
  section on why, the same split documentation.nvim draws between `:DocMap`
  and `:DocBrowse`.
- **`config/init.lua` + `config/DEFAULTS.lua`, a `bindings/` folder, and a
  top-level `@types/init.lua`.** **Done (2026-08-03)** — the single
  `config.lua` became a folder (`require("runtime-analysis.config")` still
  resolves to it unchanged, so no call site moved); `:RARequest`/`:RASend`'s
  registration moved out of `init.lua` into `bindings/usrcmds.lua`. No
  `keymaps.lua`/`autocmds.lua` were added beside it — this plugin sets
  neither, by design, so there was nothing to move into either file.

---

## Deliberately not building

| Idea | Why not | Revisit if |
|---|---|---|
| **A general Lua profiler** | `:profile` and LuaJIT's profiler exist and are better at it; this module's premise is cheap-and-always-on, which is a different instrument (§3.5) | Realistically never — point at the real profiler instead |
| **A standalone binary / web app** | `docs/ECOSYSTEM.md` §6 costed this in full and answered "a Neovim plugin": every input this needs already lives in the editor, and a separate process would have to re-acquire all of it | The data outgrows what an editor session can hold — nowhere near true |
| **Telemetry that leaves the machine** | No account, no upload, no aggregation service. The word "telemetry" carries an expectation this deliberately does not meet, and the README should probably say so more loudly than it does | Never |
| **Sending requests from documentation.nvim's static HTML page** | A browser page cannot `pcall(require, ...)` a Neovim plugin — this is why step 6 became an editor mode instead. Not a gap, a category error | Never |
| **Owning the `.http` filetype** | VS Code REST Client's syntax files and IntelliJ's already exist and are what people have; matching their shape (which `parse.lua` deliberately does) beats claiming the filetype | Never |
