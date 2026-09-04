-- scripts/bench_overhead.lua — reproducible measurement backing the
-- overhead table in lua/runtime-analysis/telemetry/README.md ("Off costs
-- nothing — literally"), and the answer to "measuring this module's own
-- instrumentation overhead": how much does turning on
-- each telemetry feature actually cost, per call, in isolation.
--
-- Deliberately NOT a runtime feature, NOT reachable from any usercmd, and
-- NOT under telemetry/ — a one-time (or occasional) dev-side benchmark you
-- run and read the numbers from, the same way a library publishes "~200ns
-- per call" in its own README. That exclusion is what lets this exist
-- without reopening the "not a general profiler"
-- rejection: nothing here is installed, left running, or user-toggleable —
-- see §3.7's own decision record in docs/FEATURE_LOG.md for the full
-- reasoning.
--
-- Usage:
--   nvim --headless -l scripts/bench_overhead.lua [--calls=200000]
--
-- Methodology: one synthetic fixture function taking two scalar arguments
-- (matching the README table's own stated "200k calls, 2 scalar args", so
-- a re-run is comparable against the numbers already published there), run
-- unwrapped (baseline) and wrapped with exactly one optional feature on at
-- a time — counting alone is the floor every other row measures against,
-- not zero, since counting is inherent to being wrapped at all. Uses
-- `vim.uv.hrtime()` (nanosecond monotonic clock), the same clock
-- `timing.lua`-shaped measurement already uses elsewhere in this
-- ecosystem (documentation.nvim's own `core/timing.lua`), not `os.clock()`
-- (CPU time, not wall time — the wrong clock for a hot-path-cost question).

vim.opt.rtp:append(vim.fn.getcwd())

---@internal
local function add_lib_nvim()
  if pcall(require, "lib.nvim.cache.disk") then
    return
  end
  local candidates = {}
  if vim.env.LIB_NVIM_DIR and vim.env.LIB_NVIM_DIR ~= "" then
    candidates[#candidates + 1] = vim.env.LIB_NVIM_DIR
  end
  candidates[#candidates + 1] = vim.fn.getcwd() .. "/.deps/lib.nvim"
  candidates[#candidates + 1] = vim.fs.dirname(vim.fn.getcwd()) .. "/lib.nvim"
  for _, dir in ipairs(candidates) do
    if dir and vim.fn.isdirectory(dir) == 1 then
      vim.opt.rtp:append(dir)
      if pcall(require, "lib.nvim.cache.disk") then
        return
      end
    end
  end
  io.stderr:write("scripts/bench_overhead.lua: lib.nvim not found.\n")
  io.stderr:write("  Set LIB_NVIM_DIR, or clone it to .deps/lib.nvim, or beside this repo.\n")
  os.exit(1)
end

add_lib_nvim()

local telemetry = require("runtime-analysis.telemetry")

---@type integer
local CALLS = 200000
for _, a in ipairs(_G.arg or {}) do
  local n = a:match("^%-%-calls=(%d+)$")
  if n then
    CALLS = tonumber(n) --[[@as integer]]
  end
end

---A fixture with real, if trivial, work — an empty function would let the
---compiler/JIT fold too much away and understate real-world overhead; two
---scalar args matches the README table's own stated shape.
---@param a integer
---@param b integer
---@return integer
local function fixture(a, b)
  return a + b
end

---@param fn fun(a: integer, b: integer)
---@param calls integer
---@return number ns_per_call
local function time_calls(fn, calls)
  local start = vim.uv.hrtime()
  for i = 1, calls do
    fn(i, i + 1)
  end
  local elapsed = vim.uv.hrtime() - start
  return elapsed / calls
end

local instance_seq = 0

---One throwaway, unpersisted instance per row — a fresh namespace and
---`persist = false` so no cache file is written and no row's counts leak
---into the next row's timing via a warmer/colder cache path.
---`remind_after = false` silences the lifecycle reminder (aimed at a
---long-lived real instance, not a benchmark that intentionally racks up
---200k calls in under a second).
---@param row_opts RA.Telemetry.StartOpts|nil
---@return number ns_per_call
local function measure(row_opts)
  instance_seq = instance_seq + 1
  local t = telemetry.new({
    namespace = "bench-overhead-" .. instance_seq,
    persist = false,
    remind_after = false,
  })
  local wrapped = t.wrap_fn(fixture, "fixture")
  t.start(row_opts)
  local ns = time_calls(wrapped, CALLS)
  t.stop()
  return ns
end

io.stdout:write(("Benchmarking %d calls per row, fixture(a, b) = a + b\n\n"):format(CALLS))

local baseline_ns = time_calls(fixture, CALLS)

local rows = {
  { label = "Counting only", opts = {} },
  { label = "+ timing", opts = { time = true } },
  { label = "+ argument profiling", opts = { profile_args = true } },
  { label = "+ call_tree", opts = { call_tree = true } },
  { label = "+ errors (pcall tax, no actual raise)", opts = { errors = true } },
}

io.stdout:write(("%-42s %12s %12s\n"):format("Mode", "ns/call", "vs baseline"))
io.stdout:write(("%-42s %12.1f %12s\n"):format("Unwrapped (baseline)", baseline_ns, "—"))

for _, row in ipairs(rows) do
  local ns = measure(row.opts)
  io.stdout:write(("%-42s %12.1f %11.1fx\n"):format(row.label, ns, ns / baseline_ns))
end

io.stdout:write(
  "\nNote: absolute numbers are machine-dependent (see the README table's own\n"
    .. "disclosure) — re-run on the machine you care about rather than trusting\n"
    .. "either this run's or the README's numbers as a universal constant.\n"
)

vim.cmd("cq 0")
