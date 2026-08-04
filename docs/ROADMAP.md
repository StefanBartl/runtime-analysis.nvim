# runtime-analysis.nvim — roadmap

A brainstormed backlog, grouped by theme. **Nothing here is scheduled**, and
several entries end in "probably not" — a documented rejection is as much a
result as a shipped feature, and worth keeping so the question does not get
re-litigated from a blank slate.

What is already built is in [the README](../README.md) and, for telemetry
specifically, in
[`lua/runtime-analysis/telemetry/README.md`](../lua/runtime-analysis/telemetry/README.md).
**When an item below ships, it is removed from here and archived in
[`docs/FINISHED.md`](FINISHED.md)** — the decision record this document
deliberately is not, kept separate so this backlog stays readable rather
than growing a struck-through "Done" note for every entry that ever ships.
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

Twenty items have shipped out of this section since it was first written —
see [`docs/FINISHED.md`](FINISHED.md) for the full record of each. What
remains open:

### Quick wins

| Item | Note |
| --- | --- |
| §6.1 Mode 8 — telemetry in `:DocBrowse` | Both halves this repo owns (`telemetry.load()`, `Data.modules`, `resolved_modules()`) already ship; what remains is documentation.nvim's entry builder, not work here |

### Medium

| Item | Note |
| --- | --- |
| §5.2 Wrapper provenance | The narrow, high-value slice of §5.1 worth shipping first; the telemetry registry already knows its own wrappers |
| §6.2 Endpoint coverage | Request history (§1.3) now exists and needs no changes; what remains is a real route-pattern-to-URL matching strategy, not just a join key |
| §6.3 Documentation priority by real usage | Needs §6.1's mechanism to exist first |
| §7.1 Keymap and command usage | Mechanically the existing wrap machinery pointed at `vim.keymap.set` plus a `CmdlineLeave` hook; stays local and opt-in, never grows a "share this" feature |
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

The README originally named four: async sending, `###` multi-request
support, request history, `.http`/`.rest` file support. **All four have
shipped** — see [`docs/FINISHED.md`](FINISHED.md) for the full record of
each. This section is intentionally left empty rather than deleted: the
number itself (`§1.x`) is still cited elsewhere in this document (§6.2)
and in `docs/FINISHED.md`, and removing the section would orphan those
references without actually freeing the number for reuse.

---

## 2. Request ergonomics

Everything here is "the runner is used daily now" work. Do none of it until
§1 is done and the thing is actually being used.

### 2.6 GraphQL / multipart / file upload

Named for completeness. GraphQL is mostly "a POST with a specific body
shape" and is cheap now that §2.1 (see `docs/FINISHED.md`) exists;
multipart file upload is a real `curl` argument-construction problem and
much less so. Neither is a priority without a concrete need.

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

### 3.5 Deliberately not: a general profiler

Neovim has `:profile`, and LuaJIT has its own profiler. This module's whole
premise is that it is *installed*, cheap and left running for a week — a
different instrument from one you switch on for thirty seconds to find a
hot loop. Competing with them would cost the property that makes this
useful. **Revisit if:** never, realistically. The right move if someone
needs a real profiler is to point at the real profiler.

---

## 4. Telemetry — reading it

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
give alone. Request history (`runtime-analysis.history`, see
[`docs/FINISHED.md`](FINISHED.md)) now exists and needs no changes to serve
this — what remains is entirely the join itself: reading
documentation.nvim's declared-route list and matching it against this
plugin's recorded URLs, which still needs a real matching strategy (a route
like `/users/:id` is not a literal string a recorded URL will ever equal).

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

### 7.3 LSP request latency

Which server is slow, on which request kind. Plausible and useful; also
squarely in territory other tools cover, and it would mean tracking
Neovim's LSP client internals across releases. Low priority.

---

## 8. Housekeeping

Not features, but the gap between "works on this machine" and "a plugin
someone else can install". Five items shipped from a `NEW_PROJECT.md`
checklist pass on 2026-08-03 — moved to
[`docs/FINISHED.md`](FINISHED.md) — leaving two still open:

- **Test coverage for the request runner's real transport.** `runner.lua`
  is currently exercised against `lib.nvim.net.curl`'s own hermetic
  `vim.uv` TCP server test at the lib.nvim end, not here. **Still open** —
  see the Medium phase above.
- **`scripts/gen_map.lua` + documentation.nvim as a dev dependency.**
  `NEW_PROJECT.md` §4 requires this (a byte-comparison `--check` gate in CI,
  the same one documentation.nvim and mdview.nvim both already run). **Not
  done** — a real, separate piece of work (a new CI job, a committed
  artifact, a new gate to keep green), not a documentation update.

---

## Deliberately not building

| Idea | Why not | Revisit if |
|---|---|---|
| **A general Lua profiler** | `:profile` and LuaJIT's profiler exist and are better at it; this module's premise is cheap-and-always-on, which is a different instrument (§3.5) | Realistically never — point at the real profiler instead |
| **A standalone binary / web app** | `docs/ECOSYSTEM.md` §6 costed this in full and answered "a Neovim plugin": every input this needs already lives in the editor, and a separate process would have to re-acquire all of it | The data outgrows what an editor session can hold — nowhere near true |
| **Telemetry that leaves the machine** | No account, no upload, no aggregation service. The word "telemetry" carries an expectation this deliberately does not meet, and the README should probably say so more loudly than it does | Never |
| **Sending requests from documentation.nvim's static HTML page** | A browser page cannot `pcall(require, ...)` a Neovim plugin — this is why step 6 became an editor mode instead. Not a gap, a category error | Never |
| **Owning the `.http` filetype** | VS Code REST Client's syntax files and IntelliJ's already exist and are what people have; matching their shape (which `parse.lua` deliberately does) beats claiming the filetype | Never |
