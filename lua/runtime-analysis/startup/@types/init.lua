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

return {}
