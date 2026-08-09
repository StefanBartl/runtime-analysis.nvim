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

Thirty-two items have shipped out of this section since it was first
written — see [`docs/FINISHED.md`](FINISHED.md) for the full record of
each. Nothing remains in active Long-term/speculative status: the one
item worth keeping at all (§4.3) moved to the "Deliberately not building"
table below, and the other (§7.3) was dropped outright — see that
section's own note.

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

§4.4 (a real dashboard) has shipped — see [`docs/FINISHED.md`](FINISHED.md)
for the full record. §4.3 (standard trace formats) was never built and is
not a live backlog item any more — moved to the "Deliberately not
building" table below, on 2026-08-04, after a look at what it would
actually take (see that table's own entry for the reasoning). This section
is intentionally left empty rather than deleted, the same reasoning §1's
own empty section states: the numbers themselves (`§4.x`) are still cited
in `docs/FINISHED.md`, and removing the section would orphan those
references without actually freeing the numbers for reuse.

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

§7.1 and §7.2 have shipped — see [`docs/FINISHED.md`](FINISHED.md) for the
full record of each. §7.3 (LSP request latency) was dropped outright, not
shipped and not deferred — asked directly on 2026-08-04. Two reasons,
both already in this document's own earlier wording: it means tracking
Neovim's LSP client internals across releases (a maintenance liability
this module's whole premise — installed, cheap, left running unattended —
is a bad fit for), and it is territory other tools, plus Neovim's own
`vim.lsp.log`, already cover. Unlike §4.3, no "revisit later" case was
made for it, so it carries no entry in "Deliberately not building" either
— this section is intentionally left empty rather than deleted, the same
reasoning §1's own empty section states, for §7.1/§7.2's own numbers.

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
| **§4.3 Standard trace formats** (speedscope's JSON / Chrome's trace format) | §3.1 shipped a flat, one-level caller histogram, not nested call stacks with timing spans — what both formats actually expect. Faithfully exporting one needs either real nested-stack tracing (which is §3.5's already-rejected general profiler by another name) or reshaping the flat data into the format anyway, which would invent nesting/timestamps that were never observed and mislead a viewer that implies more precision than exists. Discussed directly on 2026-08-04 — an idea, not a blocked backlog item | After some time — a lightweight, honestly-labeled flame-graph-*shaped* view built into this module's own dashboard (§4.4, already shipped) rather than exported into a format that promises a real trace, or if this module's own data model ever grows real nested call stacks |
