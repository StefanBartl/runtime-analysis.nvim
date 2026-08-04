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
plugin has. Steps 1–8 there have all shipped (see `docs/FINISHED.md`);
step 9 (full-file previews / a browser request runner / a Runtime tab
under `serve`) is entirely documentation.nvim's own, gated on its serve
tier — nothing left below is genuinely next rather than Long-term or
speculative.

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

Thirty-one items have shipped out of this section since it was first
written — see [`docs/FINISHED.md`](FINISHED.md) for the full record of
each. Every remaining open item is Long-term/speculative:

### Long-term / speculative

| Item | Note |
| --- | --- |
| §4.3 Standard trace formats | §3.1 (call trees) shipped, so this is no longer *meaningless* — but a real trace format needs nested call stacks and timing spans, not the flat one-level caller histogram §3.1 actually built; still separate, unbuilt work |
| §4.4 A real dashboard rather than a report | Revisited 2026-08-04 and deliberately left open — no evidence yet that the Markdown report actually feels limiting, this section's own stated precondition |
| §7.3 LSP request latency | Explicitly low priority; territory other tools already cover well |


## 1. HTTP request runner — the stated gaps

The README originally named four: async sending, `###` multi-request
support, request history, `.http`/`.rest` file support. **All four have
shipped** — see [`docs/FINISHED.md`](FINISHED.md) for the full record of
each. This section is intentionally left empty rather than deleted: the
number itself (`§1.x`) is still cited in `docs/FINISHED.md`, and removing
the section would orphan those references without actually freeing the
number for reuse.

---

## 2. Request ergonomics

§2.1–2.6 have all shipped — see [`docs/FINISHED.md`](FINISHED.md) for the
full record of each. This section is intentionally left empty rather than
deleted, the same reasoning §1's own empty section states: the number
itself (`§2.x`) is still cited in `docs/FINISHED.md`, and removing the
section would orphan those references without actually freeing the
number for reuse.

---

## 3. Telemetry — what gets collected

The module counts calls, times them, fingerprints arguments and bounds its
own cardinality. Everything below is about the *shape* of what it records,
not about reading it (that is §4).

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
the Chrome trace format. §3.1 (call trees, see `docs/FINISHED.md`) shipped
a flat, one-level caller histogram — real per-function evidence of "by
whom", but not the nested call stacks with timing spans a trace-format
viewer actually expects. Still nothing a trace format could faithfully
render; the Markdown report's own `← 61 % lua/fs/init.lua:42` line already
covers what the current data can honestly show.

### 4.4 A real dashboard rather than a report

The mdview bridge renders a Markdown document that happens to update. A
purpose-built HTML view (sortable, filterable, the way
documentation.nvim's Analysis tab is) would be better — and is exactly the
kind of thing that should be *stolen* from documentation.nvim's renderer
rather than written twice. Worth doing only if the Markdown report is
actually being read often enough to feel limiting.

**Revisited 2026-08-04, deliberately left open.** `docs/IDEAS.md` §3.1
poses the three-way choice (steal documentation.nvim's renderer, ride
mdview's relay, or stay in Markdown) and explicitly says this document
should not answer it unilaterally — asked directly, and the answer was
"not yet": no evidence exists that the Markdown report is actually
feeling limiting, which is this very section's own stated precondition
for building anything at all. Recorded so the same question does not get
re-litigated from a blank slate before that evidence exists.

---

## 5. Runtime inspection — a second pillar

§5.1 (`:RA inspect <module>`) has shipped — see
[`docs/FINISHED.md`](FINISHED.md) for the full record. This section is
intentionally left empty rather than deleted, the same reasoning §1's own
empty section states: the number itself (`§5.x`) is still cited in
`docs/FINISHED.md`, and removing the section would orphan that reference
without actually freeing the number for reuse.

---

## 6. The static × runtime join

The reason two plugins exist. `documentation.nvim/docs/ECOSYSTEM.md` §7 has
the full argument; these are the concrete pieces. §6.1, §6.2 and §6.3 have
all shipped — see [`docs/FINISHED.md`](FINISHED.md) for each — leaving
this section intentionally empty rather than deleted, the same reasoning
§1's own empty section states.

---

## 7. Editor and session analytics

Speculative, and grouped separately because it is a different *product*
than everything above — instrumenting the editor rather than instrumenting
code.

### 7.3 LSP request latency

Which server is slow, on which request kind. Plausible and useful; also
squarely in territory other tools cover, and it would mean tracking
Neovim's LSP client internals across releases. Low priority.

---

## 8. Housekeeping

Not features, but the gap between "works on this machine" and "a plugin
someone else can install". All seven items from a `NEW_PROJECT.md`
checklist pass have now shipped — moved to [`docs/FINISHED.md`](FINISHED.md).

---

## Deliberately not building

| Idea | Why not | Revisit if |
|---|---|---|
| **A standalone binary / web app** | `docs/ECOSYSTEM.md` §6 costed this in full and answered "a Neovim plugin": every input this needs already lives in the editor, and a separate process would have to re-acquire all of it | The data outgrows what an editor session can hold — nowhere near true |
| **Telemetry that leaves the machine** | No account, no upload, no aggregation service. The word "telemetry" carries an expectation this deliberately does not meet, and the README should probably say so more loudly than it does | Never |
| **Sending requests from documentation.nvim's static HTML page** | A browser page cannot `pcall(require, ...)` a Neovim plugin — this is why step 6 became an editor mode instead. Not a gap, a category error | Never |
| **Owning the `.http` filetype** | VS Code REST Client's syntax files and IntelliJ's already exist and are what people have; matching their shape (which `parse.lua` deliberately does) beats claiming the filetype | Never |
