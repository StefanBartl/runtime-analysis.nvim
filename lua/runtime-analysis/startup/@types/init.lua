---@meta
---@module 'runtime-analysis.startup.@types'

---@alias RA.Startup.MarkKind "event"|"plugin"|"lsp"|"stall"

---@class RA.Startup.Mark
---@field at number             Seconds since the run started.
---@field kind RA.Startup.MarkKind
---@field text string           Empty for stalls.
---@field late? number          Stalls only: blocked milliseconds.

---@class RA.Startup.Opts
---@field interval_ms? integer  How often the timer asks to run (default 20).
---@field stall_ms? integer     Only lateness at or above this is a stall (default 80).
---@field duration_ms? integer  Auto-report after this long; 0 = measure until stopped (default 12000).
---@field log_file? string      Written on report; "" to write none (default "ra-startup.log").
---@field notify? boolean       Show the report as a notification (default true).

---@class RA.Startup.State
---@field t0 integer            hrtime at start.
---@field last integer          hrtime of the timer's previous tick.
---@field marks RA.Startup.Mark[]
---@field opts RA.Startup.Opts
---@field group integer|nil     Autocommand group id, cleared on stop.
---@field timer uv.uv_timer_t|nil

---@alias RA.Startup.Profile.Kind "sourced"|"event"

---One measured entry, averaged across every run it appeared in.
---@class RA.Startup.Profile.Entry
---@field name string           The sourced script's path, or the event's text.
---@field kind RA.Startup.Profile.Kind
---@field median_ms number      The headline number: startup timing is skewed by outliers, so the middle run is the honest one.
---@field mean_ms number
---@field min_ms number
---@field max_ms number
---@field stddev_ms number      Spread across runs. A large one next to a large median means "measure again", not "fix this".
---@field runs integer          How many runs this entry appeared in; `< total_runs` means it did not load every time.
---@field samples number[]      The per-run values, in run order.

---@class RA.Startup.Profile.Report
---@field entries RA.Startup.Profile.Entry[]  Sorted per `opts.sort`, truncated per `opts.top`.
---@field total_ms number       Median of each run's own last clock value — the whole startup, not the sum of the rows.
---@field runs integer          Runs that produced a parseable log.
---@field failed integer        Runs that did not.
---@field nvim string           The binary that was measured.
---@field argv string[]         The arguments it was measured with.

---@class RA.Startup.Profile.Opts
---@field runs? integer         How many times to start Neovim (default 5).
---@field nvim? string          Binary to measure (default `v:progpath`).
---@field args? string[]        Extra arguments, e.g. a file to open (default none).
---@field clean? boolean        Measure `--clean` instead of the real config — the baseline to compare against (default false).
---@field sort? "median"|"total"|"name"  Default "median".
---@field top? integer          Keep only the first N entries after sorting; 0/nil keeps all (default 25).
---@field on_progress? fun(done: integer, total: integer): nil  Called after each run finishes, failed ones included.

return {}
