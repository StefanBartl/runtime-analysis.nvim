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

--- "auto" (default) prefers mdview if loadable, else the kit float — same
--- degrade-silently discipline as `lib.nvim.progress`'s style resolution.
---@alias RA.Telemetry.ReportStyle "auto"|"kit"|"mdview"|"file"

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
---@field sample? integer                      # docs/ROADMAP.md §3.2 — only every Nth call pays for args/time/errors/outermost_only; `calls` itself is always exact. Structural, like `outermost_only`: set at wrap()-time, not toggleable via StartOpts.
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

---@class RA.Telemetry.Report
---@field namespace string
---@field running boolean
---@field disabled boolean
---@field modes { counting: boolean, args: boolean, timing: boolean, errors: boolean }
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

---@class RA.Telemetry
---@field new fun(opts: RA.Telemetry.Options): RA.Telemetry.Instance
---@field auto fun(opts: RA.Telemetry.AutoOpts): RA.Telemetry.Instance|nil
---@field instances fun(): RA.Telemetry.Instance[]
---@field get fun(namespace: string): RA.Telemetry.Instance|nil
---@field load fun(namespace: string, opts?: Lib.Cache.Opts): RA.Telemetry.Data|nil
---@field report_all fun(opts?: RA.Telemetry.ReportOpts): RA.Telemetry.Report[]
---@field markdown_all fun(opts?: RA.Telemetry.ReportOpts): string[]
---@field setup fun(opts?: { report_style?: RA.Telemetry.ReportStyle }): nil
---@field flush_all fun(): integer
---@field stop_all fun(): integer
---@field disable fun(namespace: string): nil
---@field enable fun(namespace: string): nil
---@field is_disabled fun(namespace: string): boolean
---@field disabled fun(): string[]

---@class RA.Telemetry.LazyPluginOpts
---@field namespace string
---@field deep? boolean
---@field profile_args? boolean
---@field timing? boolean
---@field persist? boolean                              # forwarded to auto()/new() (default true)
---@field dir? string                                   # forwarded to auto()/new() -- cache directory override

---@class RA.Telemetry.LazyOpts
---@field plugins table<string, RA.Telemetry.LazyPluginOpts>       # keyed by repo, e.g. "StefanBartl/markdown.nvim"
---@field lib_nvim? { profile_args?: boolean, timing?: boolean, persist?: boolean, dir?: string }|false

return {}
