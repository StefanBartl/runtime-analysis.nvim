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

### §5.1 `:RA inspect <module>`

"Runtime inspection — a second pillar," and the most on-thesis idea in
the whole document: inspect what is actually loaded, right now. lib.nvim's
own roadmap turned this down as `:LibInspect` — "actually
executing/requiring code is a different trust model than docmap's pure
static scan" — and named a future tool as the right home; this plugin is
that tool.

Walks a live `package.loaded[module]` table and renders it: functions
(upvalue counts, source location — the same `debug.getinfo` primitives
`provenance.lua`, §5.2, already uses for a single function), nested
tables (their own shape), metatables, and which direct keys *shadow* a
table `__index`. New top-level module
[`lua/runtime-analysis/inspect.lua`](../lua/runtime-analysis/inspect.lua),
wired up as `:RA inspect <module>` (`<Tab>`-completing live against
`package.loaded`, the same dynamic-completer shape `:RA env` already
uses for environment names).

**The three open design questions lib.nvim's rejection left unanswered,
each resolved on its own terms, not by default:**

1. **Cycle and depth limits when walking a live table.** Cycle-*safety*
   comes from an identity-keyed `seen` set tracking the current ancestor
   chain — the same convention lib.nvim's own `lib.lua.tables.deep_copy`
   already uses for the identical reason — which alone guarantees
   termination on a table with a real cycle in it, no depth cap
   required for correctness. `max_depth` (default 3) is a *separate*,
   purely cosmetic readability cap on top of that: enough to see through
   this section's own motivating example, "a config table after three
   merge passes." A table shared between two sibling branches (not
   nested in itself) is walked in full both times, not falsely flagged
   as a cycle — the ancestor-chain set is cleared on return from each
   branch, not accumulated forever.
2. **Whether to call into `__index` functions.** Never. A direct key
   also reachable through a *table* `__index` is reported as shadowing
   it — answerable by comparing keys, no invocation needed. When
   `__index` is a function, only its presence is reported: calling it
   would be a real side effect on the code being inspected, the same
   "record it, don't guess it" trade-off `documentation.core.loaded_diff`
   and `endpoint_coverage.lua` already take elsewhere in this ecosystem
   (§5.3, §6.2). `:RA inspect` stays a pure read.
3. **Where the result renders.** `lib.nvim.ui.kit.viewer`, falling back
   to `vim.notify` when kit is unavailable — not actually a fresh
   decision by the time this shipped: `telemetry/command.lua`'s own
   `show` and `:RA usage` already established this exact convention for
   every other report in this plugin, so `:RA inspect` just plugs into
   it rather than picking a fourth rendering surface.

Full writeup: `docs/COMMANDS.md`'s own `:RA inspect <module>` section.

### §5.3 Diff loaded-vs-declared

"The sharpest form of the static × runtime join" this document names —
and the one item on this list that genuinely needed new work on *both*
sides, not just a join module on documentation.nvim's end.

**This repository's own half:** a new `runtime-analysis.loaded` module,
deliberately thin — `M.functions(module_id)` walks `package.loaded[module_id]`
one level deep and returns its string-keyed, function-valued fields;
`M.is_loaded(module_id)` is a plain existence check. No cycle handling, no
`__index` traversal, none of the three open design questions §5.1's
`:RAInspect` still carries unanswered — this module answers a much
narrower question (*is this field a function, right now, on this table*)
that needs none of them. The one honest limit that shapes everything
built on top of it: `package.loaded` reflects *this* Neovim process, so
the module is only meaningful when analyzing the very session doing the
analysis — the identical caveat the telemetry join (§6.1) and endpoint
coverage (§6.2) already state for their own "no data" cases.

**Shipped entirely as new work in
[documentation.nvim](https://github.com/StefanBartl/documentation.nvim)**
— a new `documentation.core.loaded_diff` module (soft dependency,
`pcall(require, "runtime-analysis.loaded")`), joined into a new 9th
`:DocBrowse` mode ("loaded"), spanning the whole tree like
Telemetry/Endpoints rather than one node's neighborhood. One row per
discrepancy: `✕` a declared, exported function `package.loaded` does not
have right now (dead file, or genuinely lazy — never required this
session), `!` the reverse, a function-valued key present on the module
table with no matching declaration (generated, wrapped with an extra key,
a typo'd export). Scope deliberately narrow, "record it, don't guess
it": only `"<table>.<field>"`-shaped declared names (exactly one dot, no
colon) are compared — the one shape a single-level `package.loaded` walk
can ever match as a direct field — so a file-local declaration or a
colon-declared method on a nested table is excluded outright rather than
guessed at, the same reasoning `endpoint_coverage.lua`'s route matching
already states for what it deliberately does not attempt.

Full writeup: documentation.nvim's `lua/documentation/editor/browse/README.md`
("Loaded mode" section) and `lua/documentation/core/loaded_diff.lua` itself.

### §6.2 Endpoint coverage

The last non-speculative Medium item. documentation.nvim knows every
route the source declares; this plugin's request history knows which
ones were actually sent. "Three of your eleven routes have never been
exercised" is a real answer neither side can give alone. Request history
(§1.3) needed no changes to serve this — what remained, exactly as this
entry said it would, was the join itself.

**Shipped entirely as new work in
[documentation.nvim](https://github.com/StefanBartl/documentation.nvim)**
— a new `documentation.core.endpoint_coverage` module, soft dependency
(`pcall(require, "runtime-analysis.history")`), joined into the existing
Endpoints browse mode as a leading `○` badge for a route history never
matched, plus real sends (timestamp + outcome) in the detail pane when
there are any. The one real design question the entry itself named —
"a route like `/users/:id` is not a literal string a recorded URL will
ever equal" — resolved to converting a declared route path into a Lua
pattern matching one segment per param (`:id` — Express/Fastify/Koa/
Connect/Restify — or `{id}` — Hapi), and extracting a recorded URL's own
path the same way regardless of whether it is a real absolute URL, a
bare path, or an unresolved `{{var}}`-templated one (`runtime-analysis.env`'s
own trap: history records the template, never the resolved value, so a
`{{baseUrl}}` prefix is stripped exactly like a real scheme+host would
be). Deliberately narrower than a full path-to-regexp implementation:
optional params, wildcards and regex routes are outside what this
pattern can express, and a route using one is simply never matched, not
matched wrong.

**One real addition on this repository's own side, small but genuine.**
`history.list()`/`history.clear()` gained an `opts.root` override —
`M.record` stays cwd-only (recording is always "I just sent a request
from *here*"), but a cross-repo reader like documentation.nvim's join
analyzes `opts.root`, which is not necessarily cwd at all, and needed
*that* project's history rather than whichever one Neovim happened to be
sitting in.

Full writeup: documentation.nvim's `lua/documentation/editor/browse/README.md`
("Endpoints mode" section) and `lua/documentation/core/endpoint_coverage.lua`
itself.

### §3.1 Call trees, not just counts

The single biggest capability gap in the whole document, gated on one
explicit precondition: measure `debug.getinfo`'s real cost before building
anything on top of it. Measured, through the real telemetry wrap
mechanism (200k calls, best-of-3, the same methodology the existing cost
table already uses) rather than a synthetic microbenchmark that would not
be comparable to it: counting alone reproduced the committed 0.014 µs
baseline, `debug.getinfo(2, "S")` (source only) added ~0.31 µs,
`debug.getinfo(2, "Sl")` (+ current line) ~0.32 µs, `debug.getinfo(2,
"Sln")` (+ name resolution) ~0.51 µs — name resolution costs ~60% more
for information a source:line pair already makes unambiguous, and it is
the identical join key documentation.nvim's own static `calls` extraction
already uses (a call edge's line number, not a resolved caller name). Shipped
with `"Sl"`, landing cheaper than the already-shipped `+ timing` tier
(0.394 µs).

**Mechanically:** a new `call_tree` opt (`WrapOpts`/`StartOpts`, the
identical `boolean|string[]|fun(key):boolean` shape `profile_args`/`time`/
`errors` already accept) that records the immediate caller — one frame of
`debug.getinfo(2, "Sl")`, captured up front in `registry.lua`'s wrapper
before the call itself, the same place argument fingerprinting already
happens — into `s.callers`, a bucket that reuses the *exact* bounded-
cardinality shape (`RA.Telemetry.ArgStats`) and the identical `accumulate()`
function `args`/`error_fp` already use: a caller site is a fingerprint like
any other, just derived from `debug.getinfo` instead of the call's own
arguments. `sample = N` applies uniformly, the same way it already gates
every other expensive mode. Rendered in both `M.lines` (`← 61 %
lua/fs/init.lua:42`) and `M.markdown` (a `### callers` table), mirroring
the argument-profile and error-profile sections exactly.

**What this deliberately is not.** A one-level caller histogram, not a
full call stack — matching the roadmap entry's own scope ("one frame of
`debug.getinfo`"), not a general profiler (§3.5's own rejection already
covers why this module does not become one). §4.3 (standard trace
formats) is not unblocked by this in the way it sounds: a real trace-
format viewer expects nested call stacks with timing spans, which this
data structurally is not — see that entry's own updated note.

Verified in `docs/TESTS/telemetry_spec.lua`: real, distinct call sites
(not fabricated line numbers) producing genuinely different fingerprints;
the busier site sorting first with the correct share; opt-in via both
`wrap()`-time and `start()`-time predicate, mirroring `profile_args`'s own
test coverage; bounded cardinality through the real `call_tree` path, not
assumed from the args test sharing the same `accumulate()` function;
sampling only paying for the lookup on the sampled subset, `calls` itself
staying exact; and markdown rendering.

### §6.1 Mode 8 — telemetry in `:DocBrowse` (§6.3 folded in)

The reason two plugins exist, per `docs/ECOSYSTEM.md`'s own framing —
shipped as the design doc specified, cross-repo. This repository's own
half (`telemetry.load()`, `Data.modules`, `resolved_modules()`) had
already shipped earlier; what landed today is entirely on
[documentation.nvim](https://github.com/StefanBartl/documentation.nvim)'s
side: a new `documentation.core.telemetry_join` module joining
`documentation.core.check.used_keys(ir)` (extracted from
`check_dead_functions`'s own body, so the check and the mode can never
quietly disagree about "has a static caller") against a
`runtime-analysis.telemetry` namespace, plus a new `telemetry` mode in
`:DocBrowse` at position 8 (not 7 — the design doc predates Endpoints
claiming position 7 first). §6.3 ("documentation priority by real usage")
turned out to be the exact same piece of work as one of this join's own
two aggregate lines, not a separate follow-on — folded into this entry
rather than getting its own.

**What actually shipped, concretely, all in documentation.nvim:**
`opts.telemetry_namespace` (new, defaults to `opts.title` — every
telemetry instance in this ecosystem is already namespaced by the
plugin's own display name); a `telemetry` browse mode badging each
function ✕/`!`/○/blank by which cell of the design doc's 2×2 table it
falls in, undecorated with a plain note for a function with no telemetry
data at all — absence of data is never rendered as if it were evidence,
here or anywhere else this join appears; `dead-function` suppression
(never escalation — the design doc's own "a prompt to look, never a
delete list" instruction applies to what silences the check too) once
telemetry proves the exact function alive; and the two aggregate lines
printed by `:DocMap`'s own CLI — documented-but-never-called (a
maintenance-cost set) and undocumented-but-called (a documentation
backlog prioritized by evidence of real use, the line the design doc
itself calls "the most immediately useful number in this whole
document").

Verified in documentation.nvim's `TESTS/browse_telemetry_spec.lua`
against a real telemetry instance when `runtime-analysis.nvim` is
reachable on the rtp — a real wrap, real calls, a real flush to disk,
read back through `telemetry.load()` with no live instance, the same
path a fresh `:DocMap check` run actually takes. Full writeup:
documentation.nvim's own `docs/ECOSYSTEM.md` step 8; the original
lib.nvim-side design and its now-fully-`**done**` status table:
[`lib.nvim/docs/ROADMAP/telemetry-documentation-bridge.md`](https://github.com/StefanBartl/lib.nvim/blob/main/docs/ROADMAP/telemetry-documentation-bridge.md).

### Housekeeping — `scripts/gen_map.lua` + documentation.nvim as a dev dependency

`NEW_PROJECT.md` §4's last unchecked box: adopt documentation.nvim's own
module map generator, per its
[`docs/REUSE.md`](https://github.com/StefanBartl/documentation.nvim/blob/main/docs/REUSE.md)
— copy two files, edit five lines. `scripts/gen_map.lua` copied verbatim
except the options table at the bottom (`source = "lua/runtime-analysis"`,
`title`, `repo_url`); `layers` and the self-rendered `docs/BINDINGS.md`
block documentation.nvim's own copy carries were deliberately *not*
copied — `layers` encodes that repository's own core/editor architecture
boundary, which this plugin has no equivalent of, and this repository's
`docs/BINDINGS.md` is explicitly hand-maintained rather than generated
(see that file's own header).

**Real bugs the first run found, not hypothetical ones.** Generating the
map cold surfaced two genuine, pre-existing documentation defects in one
pass: a dead link in `lua/runtime-analysis/telemetry/README.md` pointing
at `../system/README.md` (a path that only ever made sense inside
lib.nvim, where `lib.nvim.system.proc_trace` actually lives — fixed to an
absolute GitHub link, the same fix shape an earlier dead-link finding in
this repo already used), and a `docs/BINDINGS.md` reference to the
`SHARED_FILE` constant `runtime-analysis.env` exports, written as a
dotted path the checker read as a missing module member. The second one
is a real limitation worth recording plainly rather than chasing:
`doc-references-missing` cross-references against `documentation.core
.docs`'s own function index (`idx.fns_by_module`), built from
`vim.treesitter`-extracted function definitions — a plain data-field
assignment on the module table is never in that index no matter what
`---@type` annotation sits above it, since the checker only ever tracked
functions. `env.lua` still gained proper `---@type string` annotations
on both exported constants (correct regardless), but the actual fix was
rewording `docs/BINDINGS.md`'s prose
to stop presenting the constant as a dotted module-member reference.

New `map` job in `.github/workflows/ci.yml`, mirroring
`docs/REUSE.md`'s own CI template exactly: checks out this repo plus
`lib.nvim` and `documentation.nvim` into `.deps/`, then
`nvim --headless -l scripts/gen_map.lua --check` — writes nothing, fails
loudly on drift or staleness rather than letting a committed
`docs/map/` quietly rot on `main`. `scripts/hooks/pre-commit` (also
copied from documentation.nvim, unmodified past its three project-specific
variables) gives the same check locally, opt-in via
`git config core.hooksPath scripts/hooks`.

`docs/map/{index.html,module_map.json,overview.md}` committed as a real
build artifact, the same convention documentation.nvim uses on itself —
`0 errors, 0 warnings, 3 info` at the moment of committing, `94/170`
published functions fully documented.

### Housekeeping — test coverage for the request runner's real transport

**Already done, and had been since this plugin's very first commit** —
this roadmap entry was simply stale. `docs/TESTS/runner_spec.lua` has
spun up a real hermetic `vim.uv` TCP server and exercised
`lib.nvim.net.curl.fetch_raw`/`fetch_raw_blocking` underneath
`runner.run`/`runner.run_async` against it since `02e9a0c` ("in-editor
HTTP request runner — the plugin's first feature") — real sockets, a real
`curl` subprocess, no mock standing in for either. Confirmed via
`git log --follow` against that file plus reading its first committed
version verbatim, not assumed from the roadmap text. No code change
needed; this entry exists only so the stale claim stops being repeated
across future roadmap edits.

### §5.2 Wrapper provenance

Given a function, say who wrapped it — the narrow, high-value slice of §5.1
("Runtime inspection — a second pillar," still unbuilt, still carrying its
own three open design questions inherited from lib.nvim's rejection of the
idea) the roadmap entry itself said should ship first. The entry's own
framing turned out to be exactly right about the shape of the answer: this
plugin's own telemetry wraps are answerable precisely; everything else
(`lib.nvim.system.proc_trace`, any of the many plugins that monkey-patch
`vim.notify`) is genuinely best-effort, and the shipped feature says so in
its own output rather than pretending otherwise.

New top-level module,
[`lua/runtime-analysis/provenance.lua`](../lua/runtime-analysis/provenance.lua):
`M.inspect(path)` takes a dotted string — `"vim.notify"`,
`"lib.nvim.notify.create"` — since a `:RA`-style command can only ever take
a string, never a live table reference. Resolution tries two strategies in
order: a global-table walk (the `vim.*` case) first, then `require()` of
the whole prefix (the `lib.nvim`-style module-field case) — and stops
there. It deliberately does not guess where a module boundary sits inside
a longer dotted path (`a.b.c.field` where `c` is a table field of module
`a.b`, not its own requirable path) — the same "a wrong guess is worse than
no answer" stance `cost_vs_use`'s own module-root join and `curl.parse`'s
own unrecognized-flag handling already take elsewhere in this plugin.

**The exact half needed one new, small query, not a new mechanism.**
`telemetry/registry.lua` already tracks every subscriber per wrapped site
(the shared wrap layer every instance goes through, per that file's own
long-standing doc-comment on why); the only thing missing was a read-only
way to ask it. New: `registry.M.info(container, field)`, sitting right
beside the existing `is_wrapped` it was modeled after, returning which
namespace(s) — by name, sorted — currently subscribe, or an empty, honest
`{ wrapped = false }` when the field has been reassigned since (checked the
identical way `is_wrapped`/`detach` already do: `container[field] ==
site.wrapper`, not merely "does a site exist").

**The best-effort half is `debug.getinfo(value, "S")`, reported as data,
not as certainty.** Where a currently-installed function was actually
*defined* (`short_src`/`linedefined`, or "defined in C" for `what == "C"`)
is the one honest signal available with no registry to consult — it cannot
say *who* installed a wrapper or *when*, only give a reader something real
to compare against where they expected the function to live. `M.lines`
appends the caveat explicitly whenever `telemetry.wrapped` is false, rather
than leaving the reader to infer the limits of what they're looking at.

New command: `:RA provenance <path>`, under the request runner's own `:RA`
verb rather than a new top-level command — this plugin does not yet have a
dedicated "runtime inspection" command surface (that's §5.1's, still
unbuilt), and a single narrow query does not warrant inventing one on its
own.

`docs/IDEAS.md` §4.1 (the cross-repo idea this entry's own roadmap text
already pointed at — a shared wrapper-registry marker convention that would
make provenance answerable for `proc_trace` and third-party wraps too, not
only this plugin's own) is updated to reflect that the best-effort half now
has a real, shipped shape to compare a future improvement against, rather
than describing a feature that did not exist yet.

Verified: `provenance_spec.lua`, against real globals and real telemetry
instances rather than stubs (provenance's whole point is inspecting what is
*actually* installed, so a fake container would only prove the fake
worked) — a real unwrapped global (`vim.trim`); every failure shape (no
dot, unresolvable container, missing field, a non-function target) with
its own distinct, checkable error; a function this plugin's own telemetry
genuinely wraps, reported by real namespace, and confirmed no longer
reported as wrapped immediately after `unwrap()` (registry state read
live, not cached); two instances wrapping the identical function, both
namespaces present, none dropped; and the `require()`-based module-path
resolution strategy, not only the global-table one.

### §7.1 Keymap and command usage

Which of your own mappings and commands you actually press — a different
*product* from everything else in this plugin, per the roadmap section's
own framing: instrumenting the editor rather than instrumenting code. The
honest use case is pruning: a config accumulates bindings for years and
nothing ever tells you which ones went cold.

**The caveat the roadmap entry itself led with, taken at face value.** This
is the first thing in this plugin that records *what the person did*
rather than *what the code did*. It ships with exactly the posture that
caveat demands: opt-in (`:RA usage start` — nothing runs on `setup()`
alone), local-only (no account, no upload, the same "deliberately not
building" posture telemetry's own table already states), and it grows no
"share this" feature.

New module, [`lua/runtime-analysis/usage.lua`](../lua/runtime-analysis/usage.lua),
built as a thin instrumentation layer over `runtime-analysis.telemetry`
rather than a second counting mechanism: one real telemetry instance
underneath, `inst.wrap_fn` wrapping a keymap's callback exactly once — at
the moment `vim.keymap.set()` is called, not on every press — the
mechanism's own intended usage rather than a workaround. Commands have no
function to intercept (`:Telescope find_files` is text typed at a prompt),
so a `CmdlineLeave` autocmd reads what was actually typed and records it
through the same instance instead, wrapping a trivial no-op exactly once
per distinct command name and re-invoking it on every subsequent press —
never a fresh registry site per keystroke.

**Honest limits, stated up front rather than discovered later.** Only
`vim.keymap.set` calls made *after* `M.start()` are ever seen, the same
"only what runs after this starts" limit `telemetry.startup` already
states for `require`. Only function-callback keymaps are tracked — a
string-rhs mapping (`vim.keymap.set('n', 'x', ':SomeCommand<CR>')`) has
nothing to wrap. A keymap's key is `"mode lhs"`, so a buffer-local mapping
sharing that exact shape with a different mapping elsewhere is combined
into one count, not tracked per-buffer. A typed command's name is read
heuristically (a leading range/count and a trailing `!` stripped), which
can occasionally misparse an unusual range.

New route family under `:RA`: a bare `:RA usage` reports current counts (a
`lib.nvim.ui.kit` float if available, `vim.notify` otherwise — the same
soft-dependency fallback `:RATelemetry`'s own `show` helper already uses);
`:RA usage start`/`:RA usage stop` toggle collection explicitly.

Tested against the real entry points, not stubs, in
[`docs/TESTS/usage_spec.lua`](../docs/TESTS/usage_spec.lua): a real
`vim.keymap.set` callback stays callable and gets counted; a real typed
command line, committed via `nvim_feedkeys`, is counted through a genuine
`CmdlineLeave`; `stop()` restores the true `vim.keymap.set`. One case is
explicitly *not* tested and says so in the spec's own comment: reproducing
a real `<Esc>`-aborted command line through `nvim_feedkeys` in a headless
instance turned out to execute the command rather than cancel it — a
property of that combination, confirmed by checking the fed command's own
side effect rather than assumed — so the shared early-return guard
(`getcmdtype() ~= ":"`) is exercised directly instead, the same shape a
real abort would leave `getcmdtype()` in.

### §7.2 Plugin cost-versus-use

What each plugin costs at startup versus how much it is actually used —
"the report that gets plugins deleted," per the roadmap entry's own
framing. Both halves the entry names (startup attribution, §3.3; per-
namespace call counts, already collected by any telemetry instance)
existed once §3.3 shipped earlier the same day; this entry is the join
between them, which the entry's own revised text was explicit was not
free.

**The join, and the wrong shortcut it deliberately avoids.** Startup
attribution groups by module *root* — a plugin's own Lua namespace,
`"markdown"` for `require("markdown.buffer")`. Telemetry groups by
*namespace* — a caller-chosen label, almost always the repo name,
`"markdown.nvim"`. The two are only sometimes the same string, and the
tempting shortcut (strip `".nvim"`, fuzzy-match the rest) was rejected on
the same ground `resolved_modules()`'s own doc-comment already states for
a related case: a wrong guess here would silently attribute one plugin's
real startup cost to a different plugin on a name collision, which is
worse than reporting nothing at all. The actual join needs no guessing —
`inst.resolved_modules()` already maps every function that resolves to a
real module path (`wrap_loaded()`/explicit `module_id` only) to that real
path, so reading the module root off each of those and matching it
against `startup.lua`'s own per-root totals joins on the one thing both
features already track honestly.

New module,
[`lua/runtime-analysis/telemetry/cost_vs_use.lua`](../lua/runtime-analysis/telemetry/cost_vs_use.lua):
`M.build`/`M.build_all` take pre-fetched inputs (a namespace's
`resolved_modules()`, its `total_calls`, and a `startup.report()`) rather
than live instances or `startup.lua` itself — a pure join, testable with
fabricated data and no coupling between the two features it combines.
`M.build_all` sorts worst-first (lowest calls-per-startup-ms — expensive
and underused), matching the roadmap entry's own stated purpose directly
rather than leaving the reader to sort a flat table by hand; entries with
unknown cost sort last, since there is nothing to judge them against.

**`startup_ms` is `nil`, never `0`, whenever cost genuinely cannot be
determined** — the identical "unmatched is not zero-calls" discipline
`resolved_modules()` already states, applied to this join too. Two distinct
reasons are told apart rather than collapsed into one vague "unknown":
no real module path resolves for this namespace at all (a `wrap()`-only
instance, no `wrap_loaded()`/`module_id` ever used), or one does resolve
but never appears in the startup report (`autostart()` was not running for
that plugin, or it loaded before `autostart()` started timing). Both
renderers name the actual reason rather than only marking the row
"unknown."

New command: `:RATelemetry cost` — no arguments, deliberately: this is
inherently cross-namespace (a per-namespace `cost` would just repeat
`report`'s own call count with one extra number, since the join needs
`startup.report()`'s whole per-root table regardless of which namespace is
being asked about), and it reads live startup data rather than anything a
telemetry instance itself persists.

Verified: `cost_vs_use_spec.lua` — a namespace whose resolved modules match
real startup roots (including summing across more than one matched root);
both unknown-cost cases with their own distinct, checkable reason text;
`build_all`'s sort order proven with a deliberately-constructed
expensive/underused vs. cheap/heavily-used pair; and both renderers on
mixed known/unknown entries, plus the empty-instance-list case. A manual
end-to-end pass (a real `require`, a real `wrap_loaded()` instance, real
calls through it) confirmed the join attributes the correct startup cost
to the correct namespace outside the test harness too.

### §3.3 Startup attribution

Which *module* a plugin's startup cost sits in, as a waterfall — lazy.nvim
already reports per-plugin totals, so the roadmap entry was explicit that
the value here is the level below that.

**The entry's own stated mechanism did not survive contact with
lazy.nvim's source, and finding that out was most of the work.** It claimed
"the lazy adapter (`telemetry.lazy`) already knows exactly when each plugin
loads, which is half the mechanism." Checked directly rather than assumed:
lazy.nvim's `loader._load` does time each plugin (`plugin._.loaded.time`,
plus a nested `Util._profiles` tree) — but that is precisely the number the
same entry says is *not* the value here. It does **not** time individual
`require`s at all: its module loader (`loader.M.loader`) resolves and
`loadfile`s a module with no timing around it, and the only nested
`Util.track` calls are for `source`ing vim files and for whole plugins. The
`User LazyLoad` autocmd `telemetry.lazy` already hooks is the wrong
instrument twice over — it fires *after* `config()` has run (too late to
measure the thing being asked about) and it is per-plugin, not per-module.
So the existing adapter turned out to be zero percent of this mechanism,
not half, and `telemetry/lazy.lua` is untouched by this entry.

What actually works, and what shipped: new standalone module
[`lua/runtime-analysis/telemetry/startup.lua`](../lua/runtime-analysis/telemetry/startup.lua),
which wraps the global `require` and times every **cache miss** — an actual
module load, never a `package.loaded` hit (that costs one table index, is
not a load, and recording it would bury the real ones). Nesting falls out
of a stack: a module's *self* time is its total minus everything it
required in turn, which is what makes the output a waterfall rather than a
list where every parent double-counts its children. Results group two ways:
per module, and per module *root* (a plugin's own Lua namespace — a
dependency-free grouping this module computes itself, without resolving
real paths or asking any plugin manager).

**Deliberately not part of a `telemetry.new()` instance**, and not wired
into `runtime-analysis.setup()` either. It measures module loads rather
than function calls: no namespace, no persistence, no day buckets, and it
is over by the time the UI is up — folding it into an instance would put
four permanently-empty fields on every report that never has startup data.
And `setup()` is far too late to be useful: by then most of a real config
is already loaded.

**The entry point was revised after shipping, and the first version was
worse.** It was documented as "call `autostart()` as the literal first line
of `init.lua`" — which works, but is an awkward thing to ask of a reader,
and invites the obviously-tempting follow-up of having the plugin *write*
that line itself on install. That idea is worth naming explicitly so it
does not get re-proposed: **an uninstalled plugin runs no code**, so it
could never remove the line again; it would outlive the plugin in a
version-controlled file, and `init.lua` is frequently not even the real
entry point (a `lua/config/` tree, `init.vim`, a Nix-managed read-only
file). Checking lazy.nvim's own startup sequence dissolved the problem
instead of working around it: `loader.M.startup` runs **every** plugin's
`init` function in one pass (step 1 of 4) *before* it loads a single plugin
(step 2), so a spec-level `init` hook is both early enough and lives in the
same block that declares the plugin — removing the plugin removes it, with
nothing left to error or clean up. The README documents that, and why, in
its own "Why `init`, and not init.lua" section.

`autostart()` pairs the start with a one-shot `UIEnter` autocmd that stops
it again — startup is over by then, and leaving the wrapper installed keeps
paying for something with nothing left to measure.

**One real bug this design has to avoid, and the test that proves it
doesn't:** a module that *raises* during load must not leave the internal
stack unbalanced, or every module loaded afterwards has its cost subtracted
from an entry that already finished. The wrapper `pcall`s and re-raises
verbatim rather than calling through directly; `startup_spec.lua` asserts
exactly this by loading a deliberately-raising module and then checking
that the *next* module still records its own real self time.

New command: `:RATelemetry startup [top]`. Namespace-free, unlike every
other subcommand — there is no namespace here to take, so the second
positional slot is a `top` count instead.

Honest limits, all stated in `telemetry/README.md` rather than discovered
later: only modules required *after* `autostart()` are ever seen (anything
already in `package.loaded` is invisible, not free — hence "the very first
line"); only the *global* `require` is wrapped, so code holding a local
reference to it, or going through `loadfile`/`package.loaded` directly,
bypasses this entirely.

Verified: `startup_spec.lua`, against real files on disk added to
`package.path` (a stubbed `require` would prove nothing about the wrapper's
own stack discipline) — `start`/`stop` idempotence and that the original
`require` is restored exactly; a parent-requires-leaf pair proving the
parent's self time genuinely excludes the child while its total includes
it; a cache hit recording nothing; the raising-module case above; and
grouping/rendering/`top`/`sort` behavior.

### §3.2 Sampling

The complement to §3.1 (call trees, still gated on measuring
`debug.getinfo`'s cost — untouched by this entry): instead of recording
every call in full detail, record every Nth. The roadmap entry's own
prediction was almost right — "mechanically straightforward" undersold one
real subtlety, caught before it shipped rather than after: the honest-
limits wording it also demanded turned out to require an actual code fix,
not just a caveat in prose.

`sample = N` (`WrapOpts`, structural like `outermost_only` — set at
`wrap()`/`wrap_loaded()` time, not via `StartOpts`) rides the same site-
level machinery `errors`/`outermost_only` already use in `registry.lua`:
`refresh(site)` now also computes `site.sample_rate` as the **minimum**
rate any subscriber wanting expensive work asks for, so the pickiest
subscriber is never starved — and a subscriber wanting expensive work with
*no* sample rate of its own disables sampling for the whole site outright
(safety over optimality: a subscriber that asked for every call in full
never silently gets fewer). `make_wrapper` gained one new check, right
after the existing "does anyone want anything expensive" guard: on a
non-sampled call, it takes the identical cheap counting-only path that
guard already uses. **`s.calls` is untouched either way** — it was already
free at 0.014 µs, and sampling exists specifically to make the *other*
modes affordable, not to touch the one that already was.

**The real subtlety, and the fix that had to ship in the same commit per
the roadmap entry's own demand:** argument- and error-fingerprint shares
(`"91 % of calls share one argument"`) were computed against the
function's own true `calls`/`errors` count. Without sampling that is
exactly equal to the fingerprinted total (every call gets fingerprinted),
so the two were interchangeable and nobody had reason to tell them apart.
Under sampling they diverge — only the sampled subset is ever
fingerprinted — and dividing by the true call count would have silently
deflated every share (a truly dominant argument, sampled 1-in-10, would
report 10 % instead of the true ~100 %, and the memoization hint would
essentially never fire again). Fixed at the root: `report.lua` gained
`fingerprint_total(stats)` (the fingerprint bucket's own `values + other`
sum) and both `top_fingerprints` call sites — argument profiling, error
fingerprinting — now divide by that instead of `stats.calls`/`stats.errors`.
This is a strict correctness fix independent of sampling too (the two
totals were always mathematically supposed to be the fingerprinted count,
not the call count; sampling only made the gap between them visible), not
merely a caveat added to work around a known limitation.

Verified: `telemetry_spec.lua` — `calls` staying exact under sampling
while `args`/`timing`/`errors` reflect only the sampled subset at the
expected rate; errors specifically (sampling and error-fingerprinting
compose, since both ride the same pcall'd branch); a 500-call, 1-in-10-
sampled dominant-argument scenario proving the memoization hint still
fires (the actual regression the share-denominator fix prevents); and two
telemetry instances wrapping the identical function at different rates,
confirming the site honors the more eager of the two for both.

### §4.2 Comparison across time windows

`report({ since = "7d" })` already existed; "this week versus last week"
did not. The roadmap entry's own prediction held: day buckets were already
stored, so this shipped as a pure report mode, no collection-side change
at all — `registry.lua`/`init.lua`'s hot path is untouched by this entry.

`store.lua` gained one new function, `M.previous_window(data, days)`,
paired with the existing `M.since(data, days)`: half-open on the boundary
they share (`since`'s own cutoff), so the two windows never overlap and
together cover exactly `2 × days` days with no double-counted boundary
day. `report.lua` gained `M.compare(data, opts)`, building on both: every
key seen in either window is classified into exactly one of three buckets
— **newly hot** (silent in the previous window, called in this one),
**went cold** (the reverse), or **changed** (called in both, sorted by
`|delta|` — the roadmap entry's own stated interest, "what changed," not
two raw tables side by side). A changed entry's `delta_pct` is relative to
its own previous count, which is exactly why a newly-hot/cold entry gets
no `delta_pct` at all — dividing by a previous count of zero is not a
percentage.

**One honest limit, surfaced rather than silently wrong:** the "previous"
window can only be as complete as retention allows. `inst.compare`'s own
`days` window pairs with the *previous* `days` window immediately before
it — a comparison spanning `2 × days` days total — and if that exceeds
`cfg.retention_days` (30 by default), older buckets in the previous window
may already be pruned. `M.compare` computes this once
(`incomplete_previous_window`) and both renderers surface it as a visible
warning line rather than a comparison that quietly under-reports the
previous total.

New instance methods, mirroring `report`/`lines`/`markdown`'s own shape
exactly: `inst.compare(opts)`, `inst.compare_lines(opts)`,
`inst.compare_markdown(opts)` (`opts.days`, default 7). New command:
`:RATelemetry compare [namespace] [days]` — the same "every instance, or
just one" shape `report`/`start`/`stop`/`reset` already share, with a
third, purely positional token (this command's argument grammar is
deliberately positional-only, per its own module doc-comment) overriding
the default window.

Verified: `telemetry_spec.lua` — `store.previous_window` against
hand-dated day buckets (a key in both windows, a key in only one, a bucket
older than either window correctly excluded); `report.compare`'s three-way
classification and `delta`/`delta_pct` math on synthetic data, plus the
`incomplete_previous_window` flag both unset (ample retention) and set (a
20-day window against 30-day retention); both renderers producing
non-empty output that names the window size; and one end-to-end pass
through a real instance — day buckets written straight to disk the same
way the existing persistence tests do, `telemetry.new()` loading them back,
`t.compare()` reporting the correct current/previous totals.

### §3.4 Error and failure fingerprinting

`errors` already counted how *often* a wrapped function raised; the roadmap
entry's own framing held exactly: recording *what* it raised turned out to
be a genuine reuse of `profile_args`'s existing bounded-cardinality
machinery, not a parallel implementation of it — the same shape
(`RA.Telemetry.ArgStats`), the same cap (`max_arg_values`), the same merge
function, now shared by two call sites instead of one.

`registry.lua`'s `make_wrapper` already `pcall`s the original whenever
`site.needs_errors` (or `needs_depth`) is set — the only change there is
computing `fingerprint.value(res[2])` on the branch that already knows the
call raised, and only when `site.needs_errors` is actually set, so a
function opted into `outermost_only` timing alone (needs_depth without
needs_errors) pays nothing new. `init.lua`'s hot-path `_record` gained one
new field, `s.error_fp`, accumulated via a helper (`accumulate`) factored
out of what had been `s.args`'s own inline bounded-cardinality logic —
factoring it out rather than duplicating it was the point, per the roadmap
entry's own "reuses" framing, not an incidental cleanup. `store.lua`'s
`merge_args` (renamed `merge_fingerprints`, since it now merges two
different kinds of fingerprint bucket) merges `error_fp` across
flush/reload the identical way `args` already does.

**Cost, stated plainly since this module's whole premise depends on being
honest about it:** zero on the success path — the fingerprint is computed
only inside the branch that already pays for `pcall` on an actual raise,
never on a normal return. The counting-only hot path (`0.014 µs`,
`telemetry/README.md`'s own measured number) is untouched; nothing here
required re-measuring it.

`report.lua` renders the new data symmetrically to argument profiles —
`top_args` renamed `top_fingerprints` (it is called for both now) — with
one real difference: an error fingerprint's share is computed against the
function's own `errors` count, not total `calls`, since "67 % of errors
were this one message" is the readable claim and "0.07 % of calls" usually
rounds to noise. `entry.error_fp`/`error_other`/`error_distinct` are
`nil`/absent for any function that never actually raised, so a
counting-only report (the common case) renders exactly as it always did.

**No new opt-in.** This rides entirely on `errors`, the flag that already
existed — a caller reading only `entry.errors` sees no change at all;
`entry.error_fp` is purely additive.

Verified: five new blocks in `telemetry_spec.lua` — dominant/secondary
error messages fingerprinted with shares computed against `errors` (not
`calls`); the strict `errors`-opt-in boundary (a function not opted in
records neither a count nor a fingerprint, mirroring `profile_args`'s own
posture); bounded cardinality (50 distinct error messages, capped at
`max_arg_values`, `other`/`distinct` both honest); and a flush + reload +
second-instance merge round-trip proving `error_fp` counts accumulate
across sessions the same way `args`/`calls` already do, not overwritten.

### §2.5 Response assertions

`# @expect status 200` (or `// @expect status 200`), checked once a real
response arrives, a mismatch surfaced via the quickfix list — the roadmap
entry's own stated scope held exactly: one directive, one thing it checks,
not the general assertion language it explicitly warned against becoming.

New module, [`lua/runtime-analysis/assertions.lua`](../lua/runtime-analysis/assertions.lua):
`extract`/`strip`, pure logic over a request block's own lines, with no
knowledge of buffers, sends, or the quickfix list at all — `extract` finds
at most one directive anywhere in the block (a second is a real, named
error, not "last one wins" silently, the same fail-loud stance
`parse.parse` already takes on a malformed header); `strip` removes it
before the block ever reaches `parse.parse`, which has no comment syntax
of its own and would otherwise misread the directive as either an invalid
request line (first in the block) or a malformed header (anywhere else).

Wired into `send_current_buffer` (`bindings/usrcmds.lua`): the directive is
extracted (and its absolute buffer line computed, for the quickfix entry)
before parsing, and checked in *both* outcome branches of the async
callback — a real response compares its status, a transport failure
(`resp_lines == nil`) counts as an automatic mismatch too, since "no
response at all" is not a case an assertion for a specific status should
silently pass. A match is a plain `vim.notify` (`✓ expect status 200`); a
mismatch populates a fresh quickfix list (`vim.fn.setqflist(..., " ")`,
replacing rather than accumulating across sends — the same "disposable,
not accumulating silently" posture `:RA history clear`/`:RATelemetry
reset` already take) with one entry pointing at the directive's own line,
and never auto-opens it — the same "never steals focus from the request
buffer" rule `:RA send` itself already keeps; `:copen` is the reader's own
call.

**One real bug caught while checking the async-callback's own bufnr
handling, not by inspection:** the quickfix entry needs the *request*
buffer's own number, but the response arrives on a later event-loop tick
by which point `vim.api.nvim_get_current_buf()` could be whatever the
reader has switched to since sending — so `source_bufnr` is captured once,
synchronously, at the top of `send_current_buffer`, and closed over by the
async callback rather than re-read when the response actually lands.

Verified: `assertions_spec.lua` — `extract`'s own directive matching (`#`
and `//` prefixes, anywhere in the block, a fuzzy near-miss correctly
*not* matching, two directives producing a named error) and `strip`'s
line-removal in isolation; an end-to-end pair in `usrcmds_spec.lua` against
two hermetic local servers (one always `200 OK`, one fixed at
`404 Not Found`) proving a pass leaves the quickfix list empty and a
failure populates it with exactly one entry — the right `bufnr`, the right
`lnum`, and text naming both the expected and actual status.

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
