# runtime-analysis.nvim — roadmap

## Intro

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

Thirty-three items have shipped out of this section since it was first
written — see [`docs/FINISHED.md`](FINISHED.md) for the full record of
each, including §3.7 (measuring this module's own instrumentation
overhead — `scripts/bench_overhead.lua`), the most recent. §4.3 and §7.3
were the last two long-term/speculative items and are both gone (§4.3
into "Deliberately not building" below; §7.3 dropped outright — see that
section's own note) — but that is not the whole picture either: §3.6 and
§5.4 remain open. Two items, current as of this pass:

| Item | Phase | Why |
| --- | --- | --- |
| **§3.6** Benchmarking / "profile++" | Medium | The blocker is a decision, not an unknown: a schema and an API shape, plus where it lives (`telemetry/` vs. a separate module) — all things the section itself names, none of them unmeasured. Still gated on the one open question that could make the whole idea moot: whether it survives §3.5's "not a profiler" thesis. |
| **§5.4** Persist loaded-vs-declared for cold viewing | Long-term **on paper, ready to re-check** | Explicitly self-classified "Long-term, not Medium" when written, blocked on "revisit alongside §4.5's implementation" — §4.5 (named/dated telemetry snapshots) has since shipped, so the stated blocking condition is now satisfied. Not reclassified to Medium here, since the actual open question §5.4 names (whether a persisted loaded-vs-declared snapshot is worth having *at all*) was never about §4.5's absence, only about timing — the real next step is asking that question against the now-real snapshot mechanism, which is what would settle the tier, not this pass. See also the fresh feedback under §5.4 itself, not yet reconciled with this framing. |

Neither is a Quick win: both are explicitly gated on a decision this
document itself says has not been made, which is by definition not what
"Quick win" describes.

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

### 3.6 Benchmarking / "profile++" — reopened, in direct tension with §3.5

Raised 2026-08-10: the idea that since telemetry already wraps and counts,
adding *timed* benchmark comparisons (two implementations of the same
function, or the same plugin across two versions, run side by side) would
cost little more. A companion idea in the same note: some way to compare
the runtime analysis of two or more plugins, or of several distinct
benchmark runs, against each other.

This is not the same shape as §3.5's rejection on its face — a benchmark
run is a bounded, opt-in, few-seconds measurement a user asks for by name,
not `debug.sethook` running unattended for a week — but it is close enough
that §3.5's own "revisit if: never, realistically" should not be read as
silently overridden here. **Not decided.** Recorded as asked, not
designed: no schema, no API shape, no decision on whether this lives in
`telemetry/` alongside the counters it would reuse or as a genuinely
separate module. A real answer needs the same kind of "does this survive
§3.5's own thesis" pass §3.5 itself got before it is anything more than an
idea in this file. **Revisit when:** someone actually sits down to design
it, at which point start by re-reading §3.5's reasoning, not by assuming
this note settles the question in the other direction.

## 4. Telemetry — reading it

§4.4 (a real dashboard) and §4.5 (named/dated snapshots) have both
shipped — see [`docs/FINISHED.md`](FINISHED.md) for the full record of
each. §4.3 (standard trace formats) was never built and is not a live
backlog item any more — moved to the "Deliberately not building" table
below, on 2026-08-04, after a look at what it would actually take (see
that table's own entry for the reasoning). This section is intentionally
left empty rather than deleted, the same reasoning §1's own empty section
states: the numbers themselves (`§4.x`) are still cited in
`docs/FINISHED.md`, and removing the section would orphan those
references without actually freeing the numbers for reuse.

---

## 5. Runtime inspection — a second pillar

§5.1 (`:RA inspect <module>`) has shipped — see
[`docs/FINISHED.md`](FINISHED.md) for the full record. §5.3
(loaded-vs-declared, `loaded.lua`) has also shipped as a live-only view —
see §4.5's own note for why "shipped" does not mean "persisted".

### 5.4 Persist loaded-vs-declared for cold viewing

Raised 2026-08-10, same source as §4.5. `loaded.lua` is deliberately,
structurally live-only — it reads `package.loaded` in *this* process, and
"declared but dead" vs. "not loaded here" is a distinction the module's
own header says can only be drawn from a live session. A
documentation.nvim panel for it (parallel to §4.5's Telemetry one) would
need a persisted snapshot the same way, but the value of a *stale* one is
genuinely lower here than for telemetry: "what was loaded a week ago"
answers a narrower question than "how often was this called over a
week", and saving one is only ever meaningful for the single session it
was taken from. **Long-term, not Medium** — unlike §4.5, this is not just
a missing API on top of an existing store; it is a real open question
whether a persisted loaded-vs-declared snapshot is worth having at all,
or whether the honest answer is that this stays a live-only view and
documentation.nvim's integration only ever gets the Telemetry half.
Revisit alongside §4.5's implementation, not before — building the
snapshot mechanism there first will make the marginal cost of asking
`loaded.lua` for the same thing obvious one way or the other.

Feedback: Hier vertehe ich nicht ganz das problem: wenn ein runtime-analses reopirt durchgefphrt wurde, kann man diesen anspeiuchern und später wi eder anschauen. Diese Reports sollen auch in `docemntaton.nvim` in denssen bereich für runtime-analyssys.nvim features, diese reportts n plugin state data (stdpath('data') vieleicht?) zuj finden, dann aufzulisten  und dann kann man einen report nach den anderen durchklicken

warm solle das ein großes problem sein?

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
