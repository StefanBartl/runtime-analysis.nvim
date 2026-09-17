---@module 'runtime-analysis.startup.profile'
---@brief Repeated, averaged `nvim --startuptime` runs — what each sourced
---file costs, over enough runs for the number to mean something.
---@description
--- **This plugin defines itself against `--startuptime` everywhere else, so
--- the first thing this module owes the reader is why it now runs it.**
---
--- `--startuptime` is not wrong. It is *early and flat*: it starts at
--- millisecond zero and stops writing at the first screen redraw, and every
--- line it writes is a peer of every other. On Neovim 0.11 it does log
--- `require('...')` alongside `sourcing <file>`, so "files, not modules" is
--- too glib — what it genuinely cannot express is the *shape*: which load
--- happened inside which, and therefore what any one of them cost on its
--- own. The two measurements this plugin already had are late and shaped:
---
--- - `runtime-analysis.startup` watches the main loop's own lateness. It sees
---   a block whatever caused it — including a libuv callback no profiler can
---   instrument — but it never says what a single file cost.
--- - `runtime-analysis.telemetry.startup` times every `require` cache miss
---   and keeps a stack while it does, so it reports self time with children
---   subtracted and a nesting depth to reconstruct the tree from — the
---   waterfall a flat log cannot be turned into. Its own doc-comment states
---   the honest limit: nothing already in `package.loaded` when it arms is
---   ever seen. On a real config that is Neovim's whole runtime, lazy.nvim
---   itself, and every plugin loaded before this one.
---
--- Three instruments, three blind spots, and the blind spots do not overlap.
--- That is the argument for this module existing; "vim-startuptime has a nice
--- buffer" is not.
---
--- ## Why repeated runs are the actual feature
---
--- `docs/FEATURES/STARTUP.md` has been telling readers to "compare medians of
--- three runs, not single numbers" since before there was any way to do it.
--- A single `--startuptime` log is close to worthless: runs of an identical
--- config scatter by hundreds of milliseconds from filesystem cache alone,
--- and on Windows from the AV filter driver on top. So every row here carries
--- a median (the headline), a spread, and how many runs it appeared in at
--- all — a row whose stddev rivals its median is an instruction to measure
--- again, not a bug to go fix.
---
--- ## Why a subprocess, and why sequentially
---
--- Startup can only be measured by starting. The runs are strictly
--- sequential: two Neovim instances starting at once compete for CPU and
--- disk and inflate each other's numbers, which would corrupt the very
--- average this module exists to produce.
---
--- **Not `lib.nvim.system.job.chain`**, which is otherwise exactly the right
--- shape (async, sequential, each step finishing before the next): it stops
--- the whole chain at the first non-zero exit. A profiler must survive one
--- bad run and say "4 of 5 runs" out loud, not quietly measure fewer than it
--- was asked for. The driver below is the same idea with that one behaviour
--- inverted, and nothing else in it worth pushing down into the library.

require("runtime-analysis.startup.@types")

local M = {}

-- ── parsing ─────────────────────────────────────────────────────────────────

--- A sourced-script line: three numbers, then `sourcing <path>`.
---
---   049.132  000.406  000.406: sourcing /usr/share/nvim/runtime/ftplugin.vim
---            ^ self+sourced    ^ self
---
--- The **third** number is the one that matters: self time, with everything
--- the file itself sourced already subtracted. Summing `self+sourced` over a
--- tree would count the same milliseconds once per level.
local SOURCED = "^%s*([%d%.]+)%s+([%d%.]+)%s+([%d%.]+):%s+(.+)$"

--- Everything else: two numbers, then a label.
---
---   000.201  000.192: locale set
---            ^ elapsed since the previous line
local EVENT = "^%s*([%d%.]+)%s+([%d%.]+):%s+(.+)$"

---One run's parsed entries, plus the run's own wall time.
---
---Pure: it takes the log's lines and returns tables. Everything that needs a
---process, a file or a clock lives in `M.run`, so the part with all the
---format knowledge in it is the part that is directly testable.
---@param lines string[]
---@return { name: string, kind: RA.Startup.Profile.Kind, ms: number }[] entries
---@return number total_ms  The run's last clock value — the startup itself.
function M.parse(lines)
  local entries, total = {}, 0

  for _, line in ipairs(lines) do
    local clock, _, self_ms, text = line:match(SOURCED)
    local kind = "sourced"

    if not clock then
      local elapsed
      clock, elapsed, text = line:match(EVENT)
      self_ms, kind = elapsed, "event"
    end

    if clock and text then
      -- The clock column is cumulative, so the largest value in the log is
      -- the startup's own total. Read as a max rather than "the last line",
      -- because the log is not guaranteed to be monotonic across the
      -- sections Neovim writes it in.
      total = math.max(total, tonumber(clock) or 0)

      if kind == "sourced" then
        -- `sourcing ` is noise once the column already says `sourced`; the
        -- path is what a reader wants to see, and what `gf` needs.
        text = text:gsub("^sourcing ", "")
      end

      -- The banner lines (`times in msec`, the two column headers) carry no
      -- numbers and never reach here, so there is nothing to filter out.
      entries[#entries + 1] = {
        name = text,
        kind = kind,
        ms = tonumber(self_ms) or 0,
      }
    end
  end

  return entries, total
end

-- ── aggregation ─────────────────────────────────────────────────────────────

---@internal
---@param values number[]
---@return number
local function median(values)
  local sorted = vim.deepcopy(values)
  table.sort(sorted)
  local n = #sorted
  if n == 0 then
    return 0
  end
  if n % 2 == 1 then
    return sorted[(n + 1) / 2]
  end
  return (sorted[n / 2] + sorted[n / 2 + 1]) / 2
end

---@internal
---Sample standard deviation (`n - 1`), not the population one: these runs
---*are* a sample of the startups this config could have, and with five of
---them the difference is not academic.
---@param values number[]
---@param mean number
---@return number
local function stddev(values, mean)
  local n = #values
  if n < 2 then
    return 0
  end
  local sum = 0
  for _, v in ipairs(values) do
    sum = sum + (v - mean) ^ 2
  end
  return math.sqrt(sum / (n - 1))
end

---Fold the per-run entry lists into one report.
---@param runs { entries: { name: string, kind: RA.Startup.Profile.Kind, ms: number }[], total_ms: number }[]
---@param opts? RA.Startup.Profile.Opts
---@return RA.Startup.Profile.Report
function M.aggregate(runs, opts)
  opts = opts or {}

  ---@type table<string, RA.Startup.Profile.Entry>
  local by_key = {}
  local order = {}
  local totals = {}

  for _, run in ipairs(runs) do
    totals[#totals + 1] = run.total_ms

    -- Within one run, a name that appears twice (a file sourced from two
    -- places) is one cost, not two samples — summed here so the run
    -- contributes exactly one value per name, which is what makes `runs`
    -- below readable as "appeared in N of M runs".
    local this_run = {}
    for _, e in ipairs(run.entries) do
      local key = e.kind .. "\0" .. e.name
      this_run[key] = (this_run[key] or 0) + e.ms
      if not by_key[key] then
        by_key[key] = {
          name = e.name,
          kind = e.kind,
          median_ms = 0,
          mean_ms = 0,
          min_ms = math.huge,
          max_ms = 0,
          stddev_ms = 0,
          runs = 0,
          samples = {},
        }
        order[#order + 1] = by_key[key]
      end
    end

    for key, ms in pairs(this_run) do
      local entry = by_key[key]
      entry.samples[#entry.samples + 1] = ms
      entry.runs = entry.runs + 1
      entry.min_ms = math.min(entry.min_ms, ms)
      entry.max_ms = math.max(entry.max_ms, ms)
    end
  end

  for _, entry in ipairs(order) do
    local sum = 0
    for _, v in ipairs(entry.samples) do
      sum = sum + v
    end
    entry.mean_ms = #entry.samples > 0 and sum / #entry.samples or 0
    entry.median_ms = median(entry.samples)
    entry.stddev_ms = stddev(entry.samples, entry.mean_ms)
    if entry.min_ms == math.huge then
      entry.min_ms = 0
    end
  end

  local sort = opts.sort or "median"
  table.sort(order, function(a, b)
    if sort == "name" then
      return a.name < b.name
    end
    local av = sort == "total" and (a.median_ms * a.runs) or a.median_ms
    local bv = sort == "total" and (b.median_ms * b.runs) or b.median_ms
    if av == bv then
      return a.name < b.name
    end
    return av > bv
  end)

  local top = opts.top == nil and 25 or opts.top
  if top and top > 0 then
    for i = #order, top + 1, -1 do
      order[i] = nil
    end
  end

  return {
    entries = order,
    -- The median of the whole-run totals, not the sum of the rows above: the
    -- rows are self times of what got sourced, and startup is more than that.
    total_ms = median(totals),
    runs = #runs,
    failed = 0,
    nvim = opts.nvim or "",
    argv = {},
  }
end

-- ── running ─────────────────────────────────────────────────────────────────

---@internal
---The argument vector for one measured start.
---@param opts RA.Startup.Profile.Opts
---@param log string
---@return string[]
local function argv(opts, log)
  local args = {}
  if opts.clean then
    args[#args + 1] = "--clean"
  end
  args[#args + 1] = "--startuptime"
  args[#args + 1] = log
  for _, a in ipairs(opts.args or {}) do
    args[#args + 1] = a
  end
  -- `+qall!`, with the bang: a config that leaves a modified buffer behind
  -- would otherwise turn the measurement into a hung process waiting on a
  -- "no write since last change" prompt nobody can answer.
  args[#args + 1] = "+qall!"
  return args
end

---Measure `opts.runs` startups and hand the finished report to `on_done`.
---
---Asynchronous, and not optionally so: each run is a whole Neovim start, and
---five of them behind a blocking call would freeze the editor for several
---seconds — longer on Windows, where the AV filter driver taxes every process
---creation.
---@param opts? RA.Startup.Profile.Opts
---@param on_done fun(report: RA.Startup.Profile.Report|nil, err: string|nil): nil
---@return nil
function M.run(opts, on_done)
  opts = opts or {}
  local total_runs = math.max(1, opts.runs or 5)
  local nvim = opts.nvim or vim.v.progpath
  local on_progress = opts.on_progress

  if vim.fn.executable(nvim) ~= 1 then
    on_done(nil, ("not executable: %s"):format(nvim))
    return
  end

  local runs, failed = {}, 0
  local first_argv = nil

  local function step(i)
    if i > total_runs then
      if #runs == 0 then
        on_done(nil, ("all %d run(s) failed"):format(total_runs))
        return
      end
      local report = M.aggregate(runs, opts)
      report.failed = failed
      report.nvim = nvim
      report.argv = first_argv or {}
      on_done(report, nil)
      return
    end

    -- A fresh log per run, because `--startuptime` *appends* to an existing
    -- file: reusing one path would have run 2 parse run 1's lines again.
    local log = vim.fn.tempname()
    local args = argv(opts, log)
    first_argv = first_argv or args

    local cmd = { nvim }
    vim.list_extend(cmd, args)

    vim.system(cmd, {
      text = true,
      -- Explicitly no stdin: a measured start must not sit waiting on a
      -- pipe, and it has nothing to read anyway.
      stdin = false,
      -- A config that hangs during startup is exactly the kind this gets
      -- pointed at, so a run that never exits must not take the report with
      -- it. The run is counted as failed and the rest still happen.
      timeout = 60000,
    }, function()
      vim.schedule(function()
        local ok, lines = pcall(vim.fn.readfile, log)
        pcall(vim.fn.delete, log)

        if ok and type(lines) == "table" and #lines > 0 then
          local entries, run_total = M.parse(lines)
          if #entries > 0 then
            runs[#runs + 1] = { entries = entries, total_ms = run_total }
          else
            failed = failed + 1
          end
        else
          failed = failed + 1
        end

        if on_progress then
          on_progress(i, total_runs)
        end
        step(i + 1)
      end)
    end)
  end

  step(1)
end

-- ── rendering ───────────────────────────────────────────────────────────────

---@internal
---A sourced path shortened to its last two components — `plenary/init.lua`
---rather than sixty characters of prefix. The full path stays in the entry,
---which is what `gf` resolves against; this is only what the column shows.
---@param name string
---@param kind RA.Startup.Profile.Kind
---@return string
local function display_name(name, kind)
  if kind ~= "sourced" then
    return name
  end
  local parts = vim.split(name:gsub("\\", "/"), "/", { plain = true })
  if #parts <= 2 then
    return name
  end
  return table.concat({ parts[#parts - 1], parts[#parts] }, "/")
end

---@param report RA.Startup.Profile.Report
---@return string[]
function M.lines(report)
  local out = {
    -- `SPREAD` rather than `±STDDEV`: `%8s` pads by bytes, and one
    -- multi-byte character in a heading shifts the whole column off the rows
    -- underneath it. The trailer spells out what the column is.
    ("  %-44s %8s %8s %8s %8s"):format("WHAT", "MEDIAN", "MEAN", "SPREAD", "RUNS"),
  }

  for _, e in ipairs(report.entries) do
    out[#out + 1] = ("  %-44s %8.2f %8.2f %8.2f %8s"):format(
      display_name(e.name, e.kind):sub(1, 44),
      e.median_ms,
      e.mean_ms,
      e.stddev_ms,
      ("%d/%d"):format(e.runs, report.runs)
    )
  end

  out[#out + 1] = ""
  out[#out + 1] = ("  ---- %.1f ms median startup over %d run(s)%s"):format(
    report.total_ms,
    report.runs,
    report.failed > 0 and (", %d failed"):format(report.failed) or ""
  )
  if report.nvim ~= "" then
    out[#out + 1] = ("  ---- %s %s"):format(
      vim.fn.fnamemodify(report.nvim, ":t"),
      table.concat(report.argv, " ")
    )
  end
  out[#out + 1] = "  SPREAD is one sample standard deviation; a row whose spread"
  out[#out + 1] = "  rivals its median is scatter, not a finding"

  return out
end

---@param report RA.Startup.Profile.Report
---@return string[]
function M.markdown(report)
  local out = {
    "# startup profile",
    "",
    ("**%.1f ms** median startup over **%d run(s)**%s"):format(
      report.total_ms,
      report.runs,
      report.failed > 0 and (", %d failed"):format(report.failed) or ""
    ),
    "",
    ("`%s %s`"):format(report.nvim, table.concat(report.argv, " ")),
    "",
    "| What | Median ms | Mean ms | Spread ms | Runs |",
    "| --- | ---: | ---: | ---: | ---: |",
  }

  for _, e in ipairs(report.entries) do
    out[#out + 1] = ("| `%s` | %.2f | %.2f | %.2f | %d/%d |"):format(
      e.name,
      e.median_ms,
      e.mean_ms,
      e.stddev_ms,
      e.runs,
      report.runs
    )
  end

  out[#out + 1] = ""
  out[#out + 1] = "_Spread is one sample standard deviation. A row whose spread rivals"
  out[#out + 1] = "its median is scatter, not a finding._"

  return out
end

---The full path the report line at buffer row `row` refers to, for `gf` —
---`nil` for the heading, an event row, the trailer, or a path that is no
---longer on disk.
---
---Addressed by row, not by re-reading the name out of the rendered line: the
---name column is elided to its last two path components and truncated to the
---column width, so the text on screen is deliberately not the path. Row 1 is
---the heading, so entry `n` is row `n + 1` — a contract `M.lines` and this
---function share and nothing else depends on.
---@param report RA.Startup.Profile.Report
---@param row integer 1-based buffer row.
---@return string|nil
function M.path_at(report, row)
  local entry = report.entries[row - 1]
  if not entry or entry.kind ~= "sourced" then
    return nil
  end
  return vim.fn.filereadable(entry.name) == 1 and entry.name or nil
end

return M
