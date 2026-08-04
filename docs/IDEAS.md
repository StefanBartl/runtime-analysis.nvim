# runtime-analysis.nvim — cross-plugin feature ideas

**Nothing here is scheduled, and nothing here is costed.** This is the layer
*before* a roadmap: ideas worth writing down so they are not re-derived, with
enough reasoning attached to judge them later. It borrows documentation.nvim's
own three-file split, which is worth keeping apart on purpose:

| Document | Holds |
|---|---|
| [`../README.md`](../README.md) + [`telemetry/README.md`](../lua/runtime-analysis/telemetry/README.md) | What shipped, and the trade-off behind it. |
| [`ROADMAP.md`](ROADMAP.md) | This plugin's **own** backlog — request-runner gaps, telemetry collection modes, `:RAInspect`, housekeeping. |
| **this file** | Ideas that only exist **between** plugins: runtime-analysis × documentation.nvim × mdview.nvim × lib.nvim. |

`ROADMAP.md` §6 already names three items of the static × runtime join. Those
are **not repeated here**, only cross-referenced — this document is the wider
sweep across all four repositories, including the seams `ROADMAP.md` does not
look at (mdview as more than a renderer, lib.nvim as the shared floor, and the
three-way cases where a feature needs all of them).

**The filter every idea below is judged against, and it is stricter than the
single-plugin one:** *neither plugin can produce this answer alone.* An idea
that one repository could ship by itself belongs in that repository's backlog,
not here — the crossing has to be load-bearing, not decorative. Several
otherwise-attractive ideas are ranked low below on exactly that ground.

---

## 0. The map — who owns what

Four repositories, one sentence of job each
([`documentation.nvim/docs/ECOSYSTEM.md`](https://github.com/StefanBartl/documentation.nvim/blob/main/docs/ECOSYSTEM.md)
§4 argued this boundary; nothing since has revised it):

| Repository | Owns | Cannot see |
|---|---|---|
| **lib.nvim** | shared primitives: `net.curl`, `cache.disk`, `git`, `ui.kit`, `usercmd`, `progress`, `notify`, `autocmd`, `fs`, `token`, `store` | anything about a *specific* plugin's semantics |
| **documentation.nvim** | static truth — what exists, what is documented, how it connects; 14 drift checks; `:DocMap`, `:DocBrowse`, the committed HTML artifact | whether any of it ever ran |
| **runtime-analysis.nvim** | runtime truth — what actually ran (telemetry), what an endpoint actually returns (the request runner) | what the source *declares* but never loaded |
| **mdview.nvim** | presentation — Markdown to a browser, sanitized, over a token-gated loopback relay | what the Markdown means |

Three of the four seams already carry traffic:

- documentation.nvim → runtime-analysis: `:DocBrowse` Endpoints mode, `gs` →
  `require("runtime-analysis").open_request(lines)` (soft, `pcall`-guarded).
- runtime-analysis → mdview: `report_style = "mdview"` → `:MDView standalone`
  against a self-rewriting report file.
- lib.nvim → runtime-analysis: `lib.strategies.telemetry_wrap`, a thin caller
  of this plugin's own public `wrap()`.

The seam with **no traffic at all** is documentation.nvim ↔ mdview.nvim, and
§3 below is about whether that is a gap or a correct absence.

---

## 1. runtime-analysis × documentation.nvim — beyond the join already planned

`ROADMAP.md` §6 has Mode 8 (telemetry in `:DocBrowse`), endpoint coverage, and
documentation-priority-by-usage. Everything below is a *different* crossing,
found by walking documentation.nvim's actual command surface and asking what
each one would answer differently with runtime evidence attached.

### 1.1 Churn × call count — the refactoring queue, finally ordered

`core/churn.lua` ranks modules by **change frequency × complexity**, Tornhill's
signal, and its own header states the weakness honestly: it is a scalarization,
so a large value on one axis outranks a moderate value on both. Telemetry
supplies the third axis nothing static can: **is anyone actually running it.**

A module that is complex, churning, and cold is a *deletion* candidate. A
module that is complex, churning and hot is a *refactoring* candidate. Today
both render identically, and they call for opposite actions. That distinction
is the single most valuable thing this crossing produces, and it needs no new
collection on either side — churn already ships, counts already persist,
`Data.modules` already maps a telemetry key back to a real module path.

**The honest limit up front:** telemetry only sees *your* usage. A module cold
on this machine may be the hot path for every other user of the plugin. The
render has to say "not called in **your** sessions", never "unused".

### 1.2 Auto-coverage × telemetry — the four-cell table nobody has

`core/coverage.lua` derives whether a function is *tested* by counting bare-name
mentions in the test tree, and documents its blind spot: a function exercised
only indirectly never lights up. Crossing it with call counts gives four cells,
each a different, actionable claim:

| | called at runtime | never called |
|---|---|---|
| **named in a spec** | fine | a test for something you never run — is the test the only caller? |
| **not named in a spec** | **hot and untested — the queue that matters** | dead, or lazy, or platform-specific (§1.5) |

The bottom-left cell is the sharpest output of this entire document: *"this ran
4 000 times last week and no spec mentions it"* is a test backlog sorted by
evidence, exactly the way `dead-function` suppression is a false-positive list
sorted by evidence. It also **repairs coverage.lua's own stated blind spot** in
one direction: an indirectly-exercised function that telemetry saw being called
is no longer invisible.

### 1.3 `:DocMap impact` weighted by runtime reach

`impact` answers "which functions do my changed lines touch, and who calls
those" — everything between a ref and the working tree, `HEAD` by default, i.e.
the pre-commit question. Every entry in that quickfix list currently weighs the
same. Weighting each by its call count turns a flat blast radius into a ranked
one: *the seventh entry in this list is the one that runs ten thousand times a
day.*

Cheap (a lookup per quickfix entry), and it lands on the one command where a
reader is already about to make a decision.

### 1.4 `:DocMap why` × call trees — the require chain vs the call chain

`why <a> <b>` walks the **static require graph** and puts each hop in the
quickfix list at the line the `require` is written on. `ROADMAP.md` §3.1
proposes recording the immediate caller per call — a *runtime* call graph.
These are two different graphs over the same tree, and the interesting output
is where they **disagree**:

- a require edge that carries no calls at all → an import kept alive by habit;
- a runtime caller pair with no static edge between them → dynamic dispatch,
  a callback, or a table the static pass cannot follow — precisely the class
  `calls.lua`'s `confidence` field exists to admit uncertainty about.

**Was strictly gated on §3.1 of `ROADMAP.md` shipping — it now has, 2026-08-04**
(see `docs/FINISHED.md`, `call_tree` opt-in via `debug.getinfo(2, "Sl")`).
Written down here because it was the payoff that justified paying that
cost, not because it is ready to build on its own: this idea is still the
cross-repo join itself (documentation.nvim's static require graph against
this module's now-real runtime caller data), unbuilt, and belongs in
whichever repo's roadmap picks it up next — most naturally documentation.nvim's,
since `:DocMap why` is its command.

### 1.5 Runtime evidence as a *check input*, not just a view

Every crossing above is a view. The stronger form is feeding runtime evidence
back into documentation.nvim's **check** pipeline, where it changes a severity
rather than a rendering. `dead-function` suppression (already designed in
[`lib.nvim/docs/ROADMAP/telemetry-documentation-bridge.md`](https://github.com/StefanBartl/lib.nvim/blob/main/docs/ROADMAP/telemetry-documentation-bridge.md))
is the first instance; the general shape is worth naming because it comes with
a rule that must not be broken:

> Runtime data may **downgrade** a check (this looks dead, but it ran — so
> `info`, not `warn`). It must never **upgrade** one, and it must never enter
> the committed artifact.

Both halves have already-written reasons. The upgrade direction would make a
check's output depend on whose machine ran it — a warning that appears for one
developer and not another is worse than no warning. The artifact half is
`ECOSYSTEM.md` §7's byte-determinism gate, which CI enforces by regenerating
and byte-comparing.

`--full`/`opts.luals` is the exact precedent for how this is allowed to work:
an explicit flag, an IR that distinguishes "did not run" (`nil`) from "ran,
found nothing" (`{}`), and a committed artifact generated **without** it.
`telemetry.load()` already returns `nil` for "never persisted" versus a
well-formed empty table, which is the same distinction one layer down — that
was not an accident, and this is the consumer it was built for.

### 1.6 `doc-references-missing`, in the other direction

**Both halves shipped 2026-08-04** — see [`docs/FINISHED.md`](FINISHED.md)'s
§6.1 entry. documentation.nvim reads prose and asks whether the entity it
names still exists; the mirror question needed runtime: is anything
documented that is never used, and is anything used constantly that no doc
mentions? Both are now the two aggregate lines `documentation.core.
telemetry_join.doc_usage_summary` prints alongside `:DocMap`'s own doc-
coverage line.

### 1.7 Endpoint inventory × request history × response shape

§6.2 (see `docs/FINISHED.md`, shipped 2026-08-04) covers "which declared
routes were never sent". The extension worth recording: the request
runner sees **what the endpoint actually returned**. Crossing a real response against the handler's documented
`@return` — or against a route whose handler carries no doc block at all
(`core/endpoints.lua` already records that) — is drift detection over an API
contract, which is this ecosystem's whole thesis applied one layer out from
where documentation.nvim can reach.

Deliberately *not* a schema validator. The useful, cheap version is "this route
is documented as returning an object and returned an array", not JSON Schema.

### 1.8 A live badge in the annotation popup

The smallest possible item in this section, listed because it is nearly free
and would be felt daily: documentation.nvim's annotation popup already renders
params, returns, prose and a bounded snippet per function. One more line —
`called 4 812× (7d)` when a namespace has data, absent entirely when it does
not — puts runtime truth exactly where a reader is already looking, with no new
mode, no new panel and no new key binding.

The popup is in-editor, so `ECOSYSTEM.md` §7's artifact constraint does not
apply. This is surface 1 in that document's own ranking, at its cheapest.

---

## 2. runtime-analysis × mdview.nvim — mdview as more than a renderer

Today mdview is one thing to this plugin: a `report_style`. The plugin ships
four capabilities beyond rendering, and each suggests a different crossing.

### 2.1 Theme parity, and who owns the report's look

`:MDView theme` switches the preview theme at runtime across five themes with
light/dark variants. The telemetry report currently inherits whatever the
browser tab already had. Reports rendered from the editor could pass the
editor's own background — a one-argument crossing, and the alternative
(rendering our own HTML) is explicitly rejected in the telemetry README for the
right reason: it would duplicate mdview's themes and immediately drift.

### 2.2 `:MDView preview-tab` — the browser-free tier

`preview-tab` renders Markdown **inside Neovim**, no relay, no browser, no
binary download. That is a fifth `report_style` sitting there unused, and it is
strictly better than the `"kit"` float for a long report: a real buffer scrolls,
searches and yanks. It also removes the one wart in the current `"auto"`
resolution — that the first `:RATelemetry open` may pause while mdview
self-installs its relay from GitHub Releases.

Cheapest idea in this section by a wide margin.

### 2.3 The request runner's response pane, rendered

A JSON or HTML response body in a plain split is the runner's weakest surface
(`ROADMAP.md` §2.2). Markdown is not the right target for a JSON body — but a
**session log** is: a request/response transcript written as Markdown, watched
by the relay, is a browser tab that updates itself as you send. mdview's
`standalone --watch` already does exactly this for the telemetry report; the
second consumer costs almost nothing because the first one already built the
bridge (`renderers/mdview.lua`).

Where this stops being right: anything interactive. A transcript is a document;
a request *builder* in the browser is §3.2's problem and much more expensive.

### 2.4 mdview's relay as the token-gated server, if a browser tier ever happens

`ECOSYSTEM.md` §6 and §9 both land here already: if a browser-side request
runner is ever built, the honest options are documentation.nvim's
self-contained page or **mdview's relay** — a Go binary that already serves a
web client behind a per-session token with Origin checks, i.e. the exact
security posture `serve.lua` would have to grow from scratch. Recorded here so
the option is not re-derived; genuinely far off, and correctly last in that
document's sequencing.

### 2.5 Instrument mdview with mdview's own bridge

Slightly circular and entirely practical: mdview is a plugin with a relay
process, a WebSocket, a WASM renderer and a self-installing binary — the most
moving parts in the ecosystem, so the most worth measuring. The lazy.nvim
adapter already makes this one line of config. The specific question worth
answering: **which of its adapter modules actually run in a normal session**,
against the ones that only exist for one platform or one failure path.

### 2.6 Borrow `:MDView diagnose`, do not build a second one

mdview writes a full component-state diagnostics report to a file and opens it.
`ROADMAP.md`'s housekeeping section wants `:checkhealth runtime-analysis`;
`diagnose` is the same idea one step further — resolved config, live instances,
which namespaces are persistently disabled, where the cache actually is, in a
file that can be attached to an issue. Worth copying the *shape*, not the code.

---

## 3. Three-way — where all of them meet

### 3.1 Two browser tiers already exist, and that is the real open question

documentation.nvim emits a self-contained interactive HTML page (no CDN, no
build step). mdview ships a Go relay plus a prebuilt web client. Both are
"Markdown/code → browser" pipelines, built independently, and **nothing
crosses between them** — the one empty seam noted in §0.

The question this document can pose but should not answer: when
runtime-analysis wants a real dashboard (`ROADMAP.md` §4.4), does it (a) steal
documentation.nvim's renderer, (b) ride mdview's relay, or (c) stay in
Markdown? Each is defensible, and the wrong move is to start writing HTML here
before deciding, because that produces a *third* pipeline. **Decide before
building, and record the decision the way `ECOSYSTEM.md` §6 recorded the
Electron one.**

### 3.2 A Runtime tab in the served artifact

`ECOSYSTEM.md` §7 surface 2, unchanged and still correct: a Runtime tab always
present in the artifact (so the page stays byte-identical) that populates from
an endpoint when served, and shows an honest empty state under `file://`.
Requires the serve tier on documentation.nvim's side and a read endpoint over
telemetry data on this side. Explicitly later than the in-editor mode — the
in-editor version has to prove the join is worth looking at often before the
expensive surface is worth building.

### 3.3 One `ECOSYSTEM.md`, four repositories reading it

A soft, real problem visible while writing this document: the architecture doc
lives in documentation.nvim, the bridge design lives in **lib.nvim**, and this
plugin's README links to both. Two consequences already observable:

- `lua/runtime-analysis/telemetry/README.md` linked
  `../../../../docs/ROADMAP/telemetry-documentation-bridge.md` — i.e. a path in
  *this* repository. The file did not move with telemetry; it is still in
  lib.nvim, correctly so (it describes the *consumer* of telemetry's data, not
  the collection). Found dead while writing this document and fixed in the same
  commit — but it was dead from the moment telemetry moved, and nothing would
  ever have reported it.
- `ECOSYSTEM.md`'s step numbering already carries one correction note (its
  "Mode 7" is Mode 8 in the real `MODES` array, which has seven entries today:
  `structure, deps, calls, types, history, trail, endpoints` — verified).

Neither is a feature. Both argue for the same small thing: cross-repository
links checked by CI, in the one ecosystem that ships a plugin whose entire
purpose is detecting where documentation and code stop agreeing. Turning
`doc-references-missing` on the docs *of its own siblings* is the most
on-thesis housekeeping idea available.

### 3.4 A shared project key, so the three plugins agree what "this project" is

Request history (`ROADMAP.md` §1.3) wants per-project scoping. documentation.nvim
scopes an artifact per repository. mdview scopes a session per `cwd`. lib.nvim
already has `fs.project_key` and a `store/project` module. If history, telemetry
namespaces and documentation.nvim's artifact all resolved "which project is
this" the same way, a per-project *combined* view becomes possible later at
zero cost. If they do not, it never does. **The cheapest decision in this
document to make early and the most expensive to retrofit.**

---

## 4. runtime-analysis × lib.nvim — the floor

Not a feature seam so much as a discipline one, but two items are real.

### 4.1 `proc_trace` and `:RAInspect` are the same technique twice

`lib.nvim.system.proc_trace` wraps `vim.fn.system`; telemetry's registry wraps
arbitrary table fields; `runtime-analysis.provenance` (`ROADMAP.md` §5.2,
shipped) answers "who wrapped this function" — but only exactly for its own
telemetry wraps; anything else (`proc_trace`, any third-party monkey-patch)
falls back to a `debug.getinfo` source-location guess, stated as best-effort
in its own doc-comment rather than pretended otherwise. Three instances of
one pattern, in two repositories, and only one of them keeps a record of
what it did. A shared, minimal **wrapper registry convention** — an
identifiable marker on an installed wrapper — would make provenance answerable
for all three instead of one. Small, and it has to be lib.nvim's, because the
alternative is this plugin knowing about a module in a library it depends on.

### 4.2 Push work down only when a second consumer exists

The counter-pressure worth writing down, since §4.1 invites the opposite:
`net.curl` gained `fetch_raw` because this plugin needed a status code and
headers, and that was correct — it is a generic gap in a generic module.
Request *history*, environments and `###` splitting are not: they are this
plugin's semantics, and pushing them into lib.nvim would repeat the mistake
`ECOSYSTEM.md` §4 argues telemetry-in-lib.nvim was. **Rule: a helper moves down
when a second consumer exists, not when it might.**

---

## 5. The rest of the ecosystem

Named for completeness, ranked honestly low.

- **markdown.nvim** — mdview's documented companion: because it transforms
  buffer *text*, its output shows up in any preview for free. Nothing for this
  plugin to build; the crossing already works and needs no code.
- **A `:checkhealth` that knows about siblings** — each plugin's health check
  currently reports its own state. Reporting *which siblings are present and at
  what version* would make the soft-dependency graph visible from inside the
  editor. Genuinely small; genuinely useful the first time a `gs` binding
  silently does nothing.
- **Editor/session analytics** (`ROADMAP.md` §7) has no cross-plugin
  dimension worth adding here, and deliberately so: it records what the
  *person* did rather than what the *code* did, and widening its reach is the
  wrong direction for the one feature in this ecosystem that needs narrowing.

---

## 6. If only five things are ever built from this document

Ranked by *value per unit of work*, not by ambition:

1. **§2.2 `preview-tab` as a report style.** Hours, not days. Removes the
   binary-download pause from the default path.
2. **§1.8 the live call-count badge in the annotation popup.** One line of
   render, in the place a reader already looks.
3. **§1.1 churn × call count.** No new collection on either side; separates
   "refactor this" from "delete this", which nothing currently does.
4. **§1.2 auto-coverage × telemetry.** Produces the hot-and-untested queue, and
   repairs `coverage.lua`'s own stated blind spot as a side effect.
5. **§3.4 the shared project key.** Not a feature at all — a decision, cheap
   now and expensive at every later point.

Note what is *absent* from that list: everything requiring a browser tier,
everything requiring `debug.getinfo` on the hot path, and everything requiring
documentation.nvim's committed artifact to change. Those are the three
expensive directions, and none of the five touches any of them.

---

## 7. Deliberately not

| Idea | Why not | Revisit if |
|---|---|---|
| **documentation.nvim hard-depending on this plugin** | `ECOSYSTEM.md` §7 states the rule and the ecosystem already applies it in four places (`progress`→fidget, `telemetry`→mdview, `check.lua`→lua-language-server, `gs`→runtime-analysis). A static analyzer that will not run without a runtime plugin has lost the property that makes it useful in CI | Never |
| **mdview.nvim depending on either analysis plugin** | mdview is presentation and knows nothing about Lua semantics. Every crossing in §2 runs in this direction only, and that asymmetry is what keeps mdview usable by people who have neither of the others | Never |
| **Runtime data in the committed artifact** | Breaks the byte-comparison gate at generation time; personal, high-churn usage data at commit time. §1.5 has the full rule, `ECOSYSTEM.md` §7 has the argument | Never |
| **A third browser pipeline** | Two already exist and neither is finished being used. §3.1 is the decision to make first | A decision from §3.1 says so explicitly |
| **Runtime evidence upgrading a check's severity** | A warning that appears on one developer's machine and not another's is worse than no warning (§1.5) | Never |
| **Sharing telemetry across machines to fix "cold on this machine ≠ unused"** | The correct fix is honest wording in the render, not an aggregation service. `ROADMAP.md`'s "telemetry that leaves the machine" row already answers this and this document does not reopen it | Never |

---

## Epistemic note

House convention: state what was verified and what was assumed.

**Verified against real source while writing this (2026-08-03):**

- `MODES` in `documentation/editor/browse/init.lua:61` has **seven** entries;
  a telemetry mode would be the eighth.
- `core/churn.lua` and `core/coverage.lua` exist and document the exact
  weaknesses §1.1 and §1.2 propose crossing away.
- `core/endpoints.lua` records whether a route's handler carries a doc block.
- `lib.nvim.net.curl` exposes a non-blocking `fetch_raw` alongside the
  `fetch_raw_blocking` this plugin uses today.
- mdview ships `standalone` (relay `--watch`), `theme`, `preview-tab`,
  `weblogs` and `diagnose` as documented commands.
- `telemetry-documentation-bridge.md` is in **lib.nvim**, not this repository —
  so the relative link in `telemetry/README.md` was dead (§3.3, fixed in the
  commit that added this file).
- `docs/ROADMAP.md` existed only as an untracked file in the main checkout when
  this document was written, which is why it links to it as though it were
  committed. It is, as of this commit.

**Assumed, not verified:** every claim about the *cost* of an idea above. No
prototype was written for any of them, and this ecosystem has already been
burned once by exactly that gap — `core/plugins.lua` passed nine hand-written
fixtures and then produced 235 false positives against one real config. Treat
every "cheap" here as a hypothesis to test against a real tree, not a result.
