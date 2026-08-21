---@meta
---@module 'runtime-analysis.telemetry.@types'

-- ---------------------------------------------------------------------------
-- Options
-- ---------------------------------------------------------------------------

--- Reminder trigger. `false` opts out entirely; otherwise the first of the two
--- thresholds to be reached fires the (single) reminder.
---@class RA.Telemetry.RemindAfter
---@field days? integer   # calendar days since collection started (default 7)
---@field calls? integer  # total recorded calls (default 50000)

---@class RA.Telemetry.Options
---@field namespace string                              # required; also the on-disk cache key
---@field dir? string                                   # override the cache directory (passed to lib.nvim.cache.disk)
---@field retention_days? integer                       # drop day buckets older than this (default 30)
---@field flush_interval_ms? integer                    # debounced periodic flush (default 60000; 0 disables)
---@field remind_after? RA.Telemetry.RemindAfter|false # lifecycle reminder (default { days = 7, calls = 50000 })
---@field persist? boolean                              # false keeps everything in memory (default true)
---@field max_arg_values? integer                       # distinct fingerprints kept per function (default 32)
---@field report_file? boolean                          # keep this namespace's Markdown report on disk, rewritten at every flush (default false); see lua/lib/nvim/telemetry/report_file.lua
---@field info? table<string, string>                   # free-form metadata bundled with the report (branch, version/release tag, commit, …) — see lib.nvim.git.info() for a ready-made source; the caller supplies it, this module never inspects a repo to guess it
---@field snapshot_retention? integer                    # per-instance override for how many named snapshots (M.snapshot(), docs/ROADMAP.md §4.5) this namespace keeps before the oldest are evicted — default M.SNAPSHOT_RETENTION (20) when unset

--- "auto" (default) prefers mdview if loadable, else the kit float — same
--- degrade-silently discipline as `lib.nvim.progress`'s style resolution.
---@alias RA.Telemetry.ReportStyle "auto"|"kit"|"preview-tab"|"mdview"|"file"|"html"

--- Scoping options for `wrap()`. `only` and `except` are exact names, never
--- patterns — `filter` is the single escape hatch for anything else.
---@class RA.Telemetry.WrapOpts
---@field only? string[]                       # wrap only these field names
---@field except? string[]                     # wrap everything but these
---@field filter? fun(name: string, fn: function): boolean
---@field profile_args? boolean                # fingerprint arguments for these functions
---@field time? boolean                        # measure duration for these functions
---@field errors? boolean                      # count raised errors for these functions
---@field outermost_only? boolean              # recursive calls count once (costs a pcall)
---@field call_tree? boolean                   # docs/ROADMAP.md §3.1 — record the immediate caller's `short_src:line` (`debug.getinfo(2, "Sl")`, ~0.32µs measured total vs ~0.014µs for counting alone)
---@field sample? integer                      # docs/ROADMAP.md §3.2 — only every Nth call pays for args/time/errors/outermost_only/call_tree; `calls` itself is always exact. Structural, like `outermost_only`: set at wrap()-time, not toggleable via StartOpts.
---@field module_id? string                    # the real Lua module path `container` came from, if known (set automatically by wrap_loaded()). Enables a consumer to resolve a wrapped key back to source; omit when the wrap prefix is not a real module path.

--- Scoping for `wrap_loaded()`: the per-function `only`/`except`/`filter`
--- vocabulary, plus the same three one level up for whole modules.
---@class RA.Telemetry.WrapLoadedOpts : RA.Telemetry.WrapOpts
---@field module_only? string[]                      # wrap only these exact module names
---@field module_except? string[]                    # wrap everything but these modules
---@field module_filter? fun(name: string): boolean  # predicate over the full module path

--- Each field takes a key list, `true` for everything, or a predicate over the
--- key — the predicate form matters once `wrap_loaded()` produces structured
--- keys, where "everything under `core.`" is a one-liner but a list is not.
---@class RA.Telemetry.StartOpts
---@field profile_args? string[]|true|fun(key: string): boolean  # argument fingerprinting
---@field time? string[]|true|fun(key: string): boolean          # duration measurement
---@field errors? string[]|true|fun(key: string): boolean        # count raised errors
---@field call_tree? string[]|true|fun(key: string): boolean     # docs/ROADMAP.md §3.1 — immediate-caller recording

---@class RA.Telemetry.ReportOpts
---@field sort? "calls"|"name"|"time"  # default "calls"
---@field top? integer                 # keep only the N busiest entries
---@field since? string|integer        # "7d" / "24h" / a day count; filters the day buckets

---@class RA.Telemetry.Comparison.Entry
---@field key string
---@field current integer
---@field previous integer
---@field delta integer                # current - previous
---@field delta_pct? number            # (current - previous) / previous; absent when previous == 0 (see new_functions instead)

---docs/ROADMAP.md §4.2 — `inst.compare()`'s own result shape.
---@class RA.Telemetry.Comparison
---@field days integer                                    # window size, both windows the same length
---@field current_total integer
---@field previous_total integer
---@field new_functions RA.Telemetry.Comparison.Entry[]    # silent in the previous window, called in this one
---@field cold_functions RA.Telemetry.Comparison.Entry[]   # called in the previous window, silent in this one
---@field changed RA.Telemetry.Comparison.Entry[]          # called in both, sorted by |delta| desc
---@field incomplete_previous_window boolean                # true when 2 × days exceeds retention_days — the previous window may already be missing pruned buckets

---`M.compare_snapshots()`'s own result shape — a snapshot-vs-snapshot
---diff, not `RA.Telemetry.Comparison`'s calendar window (no `days`, since
---two snapshots can be arbitrarily far apart; labelled by name instead).
---@class RA.Telemetry.SnapshotComparison
---@field namespace string
---@field name_a string                                     # the earlier snapshot's name
---@field name_b string                                     # the later snapshot's name
---@field total_a integer
---@field total_b integer
---@field new_functions RA.Telemetry.Comparison.Entry[]      # silent in name_a, called in name_b
---@field cold_functions RA.Telemetry.Comparison.Entry[]     # called in name_a, silent in name_b
---@field changed RA.Telemetry.Comparison.Entry[]            # called in both, sorted by |delta| desc

-- ---------------------------------------------------------------------------
-- Collected data
-- ---------------------------------------------------------------------------

---@class RA.Telemetry.Timing
---@field n integer
---@field total_ms number
---@field min_ms number
---@field max_ms number

---@class RA.Telemetry.ArgStats
---@field values table<string, integer>  # fingerprint -> count
---@field other integer                  # calls whose fingerprint did not fit in `values`
---@field distinct integer               # distinct fingerprints seen, including evicted ones
---@field n? integer                     # size of `values`, tracked so the hot path never counts keys

---@class RA.Telemetry.FnStats
---@field calls integer
---@field errors? integer
---@field timing? RA.Telemetry.Timing
---@field args? RA.Telemetry.ArgStats
---@field error_fp? RA.Telemetry.ArgStats  # docs/ROADMAP.md §2.5 — same shape as `args`, fingerprinting the raised error instead of the call's arguments
---@field callers? RA.Telemetry.ArgStats   # docs/ROADMAP.md §3.1 — same shape as `args`, fingerprinting the immediate caller's `short_src:line` instead of the call's arguments

---@class RA.Telemetry.Data
---@field version integer
---@field started_at integer                                  # os.time() of the first collection
---@field sessions integer
---@field functions table<string, RA.Telemetry.FnStats>
---@field days table<string, table<string, integer>>          # "YYYY-MM-DD" -> key -> calls
---@field reminded table<string, boolean>                     # threshold name -> already notified
---@field modules table<string, string>                       # wrapped key -> real Lua module path, only for keys this module can resolve (see WrapOpts.module_id / wrap_loaded); a key with no entry is unmatched, not zero-calls
---@field info table<string, string>                          # free-form metadata from Options.info — last-write-wins on merge, not accumulated, since a newer session's branch/version supersedes an older one rather than adding to it

---@class RA.Telemetry.ReportEntry
---@field key string
---@field calls integer
---@field errors integer
---@field mean_ms? number
---@field min_ms? number
---@field max_ms? number
---@field args? { fingerprint: string, count: number, share: number }[]
---@field other? integer
---@field distinct? integer
---@field hint? string   # e.g. the "dominant argument -> memoize" suggestion
---@field error_fp? { fingerprint: string, count: number, share: number }[]  # docs/ROADMAP.md §2.5 — share is of `errors`, not `calls`
---@field error_other? integer
---@field error_distinct? integer
---@field callers? { fingerprint: string, count: number, share: number }[]  # docs/ROADMAP.md §3.1 — `fingerprint` is a `short_src:line` call site; share is of `calls`
---@field callers_other? integer
---@field callers_distinct? integer

---@class RA.Telemetry.Report
---@field namespace string
---@field running boolean
---@field disabled boolean
---@field modes { counting: boolean, args: boolean, timing: boolean, errors: boolean, call_tree: boolean }
---@field started_at integer
---@field sessions integer
---@field total_calls integer
---@field wrapped integer
---@field since? string
---@field info table<string, string>
---@field entries RA.Telemetry.ReportEntry[]

-- ---------------------------------------------------------------------------
-- Startup attribution (docs/ROADMAP.md §3.3)
-- ---------------------------------------------------------------------------

---One module load, timed. `self_ms` excludes everything this module required
---in turn (which is what makes the report a waterfall rather than a list
---where every parent double-counts its children); `total_ms` includes it.
---@class RA.Telemetry.Startup.Entry
---@field modname string
---@field total_ms number
---@field self_ms number
---@field depth integer      # how deep in the require chain this load started
---@field errored? boolean   # the module raised while loading; its timing is still recorded

---@class RA.Telemetry.Startup.Report
---@field running boolean
---@field total_ms number                                  # sum of every module's self time
---@field modules RA.Telemetry.Startup.Entry[]
---@field roots { root: string, self_ms: number }[]        # per module-root (a plugin's own Lua namespace) totals, descending

-- ---------------------------------------------------------------------------
-- Cost vs. use (docs/ROADMAP.md §7.2)
-- ---------------------------------------------------------------------------

---One namespace's startup-cost-vs-call-count entry. `startup_ms`/
---`calls_per_ms` are `nil` — not `0` — when no real module path this
---namespace's own calls resolve to appears anywhere in the startup report;
---`reason` explains which of the two honest-limit cases that is.
---@class RA.Telemetry.CostVsUse.Entry
---@field namespace string
---@field total_calls integer
---@field startup_ms? number
---@field matched_roots string[]         # which of this namespace's own resolved module roots actually had startup data
---@field resolved_root_count integer    # how many distinct real module roots this namespace's calls resolve to at all, known or not
---@field calls_per_ms? number           # total_calls / startup_ms; nil whenever startup_ms is
---@field reason? string                 # set only when startup_ms is nil

-- ---------------------------------------------------------------------------
-- Instance
-- ---------------------------------------------------------------------------

---@class RA.Telemetry.Instance
---@field namespace string
---@field wrap fun(container: table, prefix?: string, opts?: RA.Telemetry.WrapOpts): integer
---@field wrap_fn fun(fn: function, key: string, opts?: RA.Telemetry.WrapOpts): function
---@field track_table fun(t: table, key: string, opts?: { reads?: boolean, writes?: boolean }): (fun(field: any): any), (fun(field: any, value: any))
---@field wrap_loaded fun(prefix: string, opts?: RA.Telemetry.WrapLoadedOpts): integer, integer
---@field unwrap fun(): nil
---@field start fun(opts?: RA.Telemetry.StartOpts): boolean
---@field stop fun(): boolean
---@field is_running fun(): boolean
---@field report fun(opts?: RA.Telemetry.ReportOpts): RA.Telemetry.Report
---@field lines fun(opts?: RA.Telemetry.ReportOpts): string[]
---@field markdown fun(opts?: RA.Telemetry.ReportOpts): string[]
---@field compare fun(opts?: { days?: integer }): RA.Telemetry.Comparison
---@field compare_lines fun(opts?: { days?: integer }): string[]
---@field compare_markdown fun(opts?: { days?: integer }): string[]
---@field coverage fun(): { called: string[], uncalled: string[] }
---@field resolved_modules fun(): table<string, string>
---@field reset fun(): nil
---@field flush fun(): boolean
---@field data_path fun(): string                     # the file this instance's counters are written to, for telling a reader where their data went
---@field wrapped_keys fun(): string[]

---@class RA.Telemetry.AutoOpts
---@field namespace string
---@field main string                                   # root Lua module to instrument
---@field deep? boolean                                 # wrap_loaded(main) instead of just its façade (default false)
---@field profile_args? boolean
---@field timing? boolean
---@field persist? boolean                              # forwarded to new() (default true)
---@field dir? string                                   # forwarded to new() -- cache directory override
---@field module_filter? fun(name: string): boolean      # default: excludes `@types` modules

---One entry in `RA.Telemetry.load_snapshots` — enough to build a picker
---without loading every snapshot's full data first.
---@class RA.Telemetry.SnapshotInfo
---@field name string Sanitized — what `RA.Telemetry.load_snapshot`/`delete_snapshot` expect back.
---@field saved_at integer Unix timestamp, the snapshot file's own mtime.

---@class RA.Telemetry
---@field new fun(opts: RA.Telemetry.Options): RA.Telemetry.Instance
---@field auto fun(opts: RA.Telemetry.AutoOpts): RA.Telemetry.Instance|nil
---@field instances fun(): RA.Telemetry.Instance[]
---@field get fun(namespace: string): RA.Telemetry.Instance|nil
---@field load fun(namespace: string, opts?: Lib.Cache.Opts): RA.Telemetry.Data|nil
---@field report_all fun(opts?: RA.Telemetry.ReportOpts): RA.Telemetry.Report[]
---@field markdown_all fun(opts?: RA.Telemetry.ReportOpts): string[]
---@field export_all fun(target_dir: string, opts?: { dir?: string, report_opts?: RA.Telemetry.ReportOpts }): string[], string[]
---@field setup fun(opts?: { report_style?: RA.Telemetry.ReportStyle }): nil
---@field start_all fun(): integer
---@field flush_all fun(): integer
---@field stop_all fun(): integer
---@field disable fun(namespace: string): nil
---@field enable fun(namespace: string): nil
---@field is_disabled fun(namespace: string): boolean
---@field disabled fun(): string[]
---@field SNAPSHOT_RETENTION integer
---@field snapshot fun(namespace: string, name?: string, opts?: { device?: string|false }): string|nil
---@field list_snapshots fun(namespace: string, opts?: Lib.Cache.Opts): RA.Telemetry.SnapshotInfo[]
---@field load_snapshot fun(namespace: string, name: string, opts?: Lib.Cache.Opts): RA.Telemetry.Data|nil
---@field compare_snapshots fun(namespace: string, name_a: string, name_b: string, opts?: Lib.Cache.Opts): RA.Telemetry.SnapshotComparison|nil
---@field module_loaded fun(main: string): boolean
---@field default_module_filter fun(name: string): boolean

---@class RA.Telemetry.LazyPluginOpts
---@field namespace string
---@field deep? boolean
---@field profile_args? boolean
---@field timing? boolean
---@field persist? boolean                              # forwarded to auto()/new() (default true)
---@field dir? string                                   # forwarded to auto()/new() -- cache directory override

---A target that is NOT a plugin -- the reader's own Neovim config being the
---motivating case, and the reason this is not simply another `plugins` entry:
---nothing about a config is resolvable through a plugin manager. It has no
---repo, no spec, and no single root module (a config's Lua tree is typically
---several unrelated top-level prefixes -- `config`, `bindings`, `lsp`, ...),
---so the caller states its prefixes outright instead of anything here
---deriving them.
---
---   extra = {
---     {
---       namespace = "nvim-config",
---       mains = { "config", "bindings", "lsp", "autocmds" },
---       profile_args = true,
---     },
---   }
---
---WHY `mains` IS A LIST AND `LazyPluginOpts` HAS NO EQUIVALENT
---A plugin is one root module by construction (that is what `lazy.core.
---loader.get_main` resolves). A config is not, and forcing one entry per
---prefix would split a single namespace across several candidates -- each
---resetting the others' data on `setup`, since they would share a cache file.
---
---TIMING (the one thing that actually makes this hard)
---A config's own modules are mostly NOT loaded while `runtime-analysis.
---setup()` runs -- that call happens inside `lazy.setup()`, before the
---config's later phases (options, autocmds, lsp, keymaps) have required
---anything. `wrap_loaded()` only ever sees what is in `package.loaded` at the
---moment it runs, so wrapping here would catch almost nothing. Hence
---`wrap_at`: instrumentation is deferred to a point where the config has
---actually finished loading.
---@class RA.Telemetry.ExtraTarget
---@field namespace string                              # e.g. "nvim-config"
---@field mains string[]                                # root Lua prefixes, e.g. { "config", "bindings" }
---@field deep? boolean                                 # wrap the whole loaded subtree (default true -- a config has no façade to wrap instead)
---@field profile_args? boolean
---@field timing? boolean
---@field persist? boolean                              # forwarded to new() (default true)
---@field dir? string                                   # forwarded to new() -- cache directory override
---@field wrap_at? RA.Telemetry.ExtraWrapAt             # when to wrap (default "VimEnter")

---When an `extra` target is wrapped and started.
---  * "VimEnter"  -- deferred to VimEnter + `vim.schedule`, i.e. once the UI
---                   is up and a normal config has finished every startup
---                   phase it runs. The default, and right for a config.
---  * "setup"     -- immediately, during `runtime-analysis.setup()`. Only
---                   correct for a target already fully loaded by then.
---  * "manual"    -- never automatically; `:RATelemetry setup <ns>` /
---                   `:RATelemetry full <ns>` are the only triggers.
---@alias RA.Telemetry.ExtraWrapAt "VimEnter"|"setup"|"manual"

---@class RA.Telemetry.LazyOpts
---@field plugins? table<string, RA.Telemetry.LazyPluginOpts>       # keyed by repo, e.g. "StefanBartl/markdown.nvim"
---@field lib_nvim? { profile_args?: boolean, timing?: boolean, persist?: boolean, dir?: string }|false
---@field extra? RA.Telemetry.ExtraTarget[]                         # non-plugin targets, chiefly the reader's own config

-- ---------------------------------------------------------------------------
-- :RATelemetrySetupAll / :RATelemetrySetupAllFull (telemetry/setup_all.lua)
-- ---------------------------------------------------------------------------

---One configured plugin `telemetry.lazy.candidates()` resolved to something
---currently loaded and therefore actually wrappable right now -- everything
---`setup_all.run()` needs to act on it without re-deriving lazy.nvim's own
---plugin table a second time.
---Also covers an `extra` (non-plugin) target -- see `repo`/`mains` below for
---the two fields that differ, both kept backwards-compatible rather than
---reshaped: `main` stayed `string` (never `string|string[]`) so every
---existing reader of this type keeps working unchanged, and `mains` is the
---additive field a multi-prefix target needs.
---@class RA.Telemetry.SetupAllCandidate
---@field repo string?                         # e.g. "StefanBartl/markdown.nvim"; nil for an `extra` target, which has no repo
---@field namespace string                     # the telemetry namespace -- same as RATelemetry.LazyPluginOpts.namespace
---@field main string                          # root Lua module, resolved via lazy.core.loader.get_main; for an `extra` target, its FIRST prefix
---@field mains string[]?                      # every root prefix, when the target has more than one (`extra` only). Readers should prefer `mains or { main }`.
---@field settings RA.Telemetry.LazyPluginOpts|RA.Telemetry.ExtraTarget # this target's own configured policy

---One candidate's outcome, in the order `setup_all.run()` processed it.
---@class RA.Telemetry.SetupAllResult
---@field namespace string
---@field had_data boolean   # true when this namespace had at least one function with recorded stats (not merely a cache file on disk -- a freshly flushed, never-called instance still writes one) before this run reset it
---@field backed_up string?  # the file it was written to, when `run_opts.backup_dir` was set and had_data is true

return {}
