---@module 'runtime-analysis.bench'
--- Timed comparisons between candidate functions —
--- "since telemetry already wraps and counts, adding timed benchmark
--- comparisons would cost little more". That premise does not survive
--- contact with real numbers, though, and this module is built on the
--- corrected version of it, not the original one.
---
--- **Deliberately NOT built on `runtime-analysis.telemetry`'s own
--- wrap/count machinery**, despite what the roadmap note assumed.
--- the own measured numbers (see
--- `scripts/bench_overhead.lua`) put counting-only overhead at ~10-15ns
--- per call and argument profiling at ~600-700ns — real costs that would
--- swamp the very comparison a benchmark is meant to make for anything
--- fast, and bias it unevenly if the candidates being compared are not
--- wrapped with identical options. A benchmark harness has to call its
--- candidates directly, the same discipline `scripts/bench_overhead.lua`'s
--- own baseline row already uses. What actually carries over from
--- telemetry is not its wrap mechanism — only the fact that this repo
--- already knows how to time things carefully (`vim.uv.hrtime()`, not
--- `os.clock()` — wall time, not CPU time).
---
--- **A separate top-level module, not nested under `telemetry/`, on
--- purpose.** Keeps telemetry's own hot-path code untouched by anything
--- benchmark-specific — the same reasoning that put §3.7's own script
--- outside `telemetry/` too. `runtime-analysis.telemetry`'s whole premise
--- ("not a general profiler") is being installed,
--- cheap, and left running for a week; a benchmark run here is the
--- opposite shape — bounded, explicit, a few seconds, called by name —
--- and does not need to share a module with something built for the
--- opposite posture to exist.
---
--- **Compare-now only, no persistence.** The roadmap note's own
--- "companion idea" (naming and comparing saved benchmark runs against
--- each other, the way §4.5/§5.4 do for telemetry/loaded snapshots) is
--- deliberately not part of this — confirmed with the user as later
--- scope, not because it is hard, but because it has not actually been
--- asked for yet. `M.compare` returns a plain table; what a caller does
--- with it (print it, save it, diff it by hand) is up to the caller.
---
--- Pure Lua API, no usercmd. Unlike `:RA inspect`/`:RA provenance`
--- (a string naming an already-loaded module/path) or `:RA loaded
--- snapshot` (a string naming a prefix), a benchmark candidate is a real
--- Lua function value — there is no command-line shape for "type the two
--- closures you want compared", so this is consumed from a script, a
--- keymap, or `:lua`, the same way Python's `timeit` module is a library
--- call, not a shell command.

local unpack_ = table.unpack or unpack

local M = {}

---@class RA.Bench.Candidate
---@field name string
---@field fn fun(...)

---@class RA.Bench.Opts
---@field iterations? integer Timed calls per candidate. Default 1000.
---@field warmup? integer Untimed calls per candidate before the timed run — lets cache/branch-predictor state settle so comparison *order* does not bias the result (the first candidate run would otherwise pay a one-time cold-state cost the others don't). Default: `min(100, iterations)`.
---@field args? any[] Fixed arguments every candidate is called with. Default: none.

---@class RA.Bench.Row
---@field name string
---@field calls integer
---@field total_ns number
---@field ns_per_call number
---@field vs_fastest number `1.0` for the fastest row, `>1` for every slower one — `ns_per_call / fastest.ns_per_call`.

---@class RA.Bench.Result
---@field rows RA.Bench.Row[] Sorted fastest first.
---@field fastest string `rows[1].name`.

---Time every candidate over the same number of calls and rank them.
---
---**Not thread/coroutine-safe against itself** — like any wall-clock
---timing, running two `M.compare` calls concurrently (e.g. from two
---coroutines) would have each one's candidates compete for CPU time and
---produce meaningless numbers for both. Call it from the main context, one
---comparison at a time, the same assumption `scripts/bench_overhead.lua`
---already makes.
---@param candidates RA.Bench.Candidate[] At least one; a single candidate is valid (its own baseline against itself, `vs_fastest = 1.0` for the only row) even though it answers no real comparison.
---@param opts? RA.Bench.Opts
---@return RA.Bench.Result|nil result `nil` when `candidates` is empty, or any entry is missing a `name`/`fn`.
---@return string|nil err Set only when `result` is `nil`.
function M.compare(candidates, opts)
  if type(candidates) ~= "table" or #candidates == 0 then
    return nil, "bench.compare: candidates must be a non-empty array"
  end
  local seen_names = {}
  for i, c in ipairs(candidates) do
    if type(c) ~= "table" or type(c.name) ~= "string" or c.name == "" then
      return nil, ("bench.compare: candidates[%d] has no string name"):format(i)
    end
    if type(c.fn) ~= "function" then
      return nil, ("bench.compare: candidates[%d] (%q) has no function"):format(i, c.name)
    end
    if seen_names[c.name] then
      return nil, ("bench.compare: duplicate candidate name %q"):format(c.name)
    end
    seen_names[c.name] = true
  end

  opts = opts or {}
  local iterations = opts.iterations or 1000
  local warmup = opts.warmup
  if warmup == nil then
    warmup = math.min(100, iterations)
  end
  local args = opts.args or {}

  local uv = vim.uv or vim.loop
  local rows = {} ---@type RA.Bench.Row[]

  for _, c in ipairs(candidates) do
    for _ = 1, warmup do
      c.fn(unpack_(args))
    end
    local start = uv.hrtime()
    for _ = 1, iterations do
      c.fn(unpack_(args))
    end
    local elapsed = uv.hrtime() - start
    rows[#rows + 1] = {
      name = c.name,
      calls = iterations,
      total_ns = elapsed,
      ns_per_call = elapsed / iterations,
      vs_fastest = 1, -- filled in below, once the fastest row is known
    }
  end

  table.sort(rows, function(a, b)
    return a.ns_per_call < b.ns_per_call
  end)

  local fastest_ns = rows[1].ns_per_call
  for _, r in ipairs(rows) do
    r.vs_fastest = fastest_ns > 0 and (r.ns_per_call / fastest_ns) or 1
  end

  return { rows = rows, fastest = rows[1].name }
end

---Render a `M.compare` result as plain lines — the same `M.lines(report)`
---shape `runtime-analysis.usage`/`runtime-analysis.inspect` already use for
---a `lib.nvim.ui.kit.viewer`/`vim.notify` fallback pair.
---@param result RA.Bench.Result
---@return string[]
function M.lines(result)
  local out = { ("%-24s %14s %10s"):format("Name", "ns/call", "vs fastest") }
  for _, r in ipairs(result.rows) do
    out[#out + 1] = ("%-24s %14.1f %9.2fx"):format(r.name, r.ns_per_call, r.vs_fastest)
  end
  return out
end

return M
