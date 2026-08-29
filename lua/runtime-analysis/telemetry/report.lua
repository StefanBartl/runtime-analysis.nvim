---@module 'runtime-analysis.telemetry.report'
--- Turns collected counters into a report table, and a report table into lines.
---
--- The formatting half is not decoration. A raw dump of counts makes the reader
--- do the analysis; the point of argument profiling is the sentence at the end
--- of an entry — "91 % of calls share one argument — candidate for memoization"
--- — which names the pattern *and* points at the tool that fixes it
--- (`lib.lua.memo`). Without that line the feature is a table of numbers.

local store = require("runtime-analysis.telemetry.store")

local M = {}

--- Below this share, "most calls pass the same thing" is not a real finding.
local DOMINANT_SHARE = 0.75

--- Below this many calls it is not a finding either — 3 of 4 is 75 % and means
--- nothing. A hint that fires on noise is a hint that gets ignored.
local DOMINANT_MIN_CALLS = 20

--- Distinct fingerprints kept per entry in the rendered report.
local ARGS_SHOWN = 3

---@internal
---@param n number
---@return string
local function num(n)
  local s = tostring(math.floor(n + 0.5))
  local out = s:reverse():gsub("(%d%d%d)", "%1 "):reverse()
  return (out:gsub("^%s+", ""))
end

---Render `Options.info`/`Data.info` as one deterministic, sorted line —
---shared by `M.lines` and `M.markdown` so the two never disagree on key
---order. `nil` when there is nothing to show, so callers can skip the line
---entirely rather than rendering an empty one.
---@internal
---@param info table<string, string>
---@return string?
local function format_info(info)
  local keys = {}
  for k in pairs(info) do
    keys[#keys + 1] = k
  end
  if #keys == 0 then
    return nil
  end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do
    parts[#parts + 1] = ("%s=%s"):format(k, tostring(info[k]))
  end
  return table.concat(parts, " · ")
end

---How many calls this fingerprint bucket actually captured (`values` +
---`other`) — the correct share denominator, *not* the function's own
---`calls`/`errors`. Without §3.2 sampling the two are always equal (every
---call is fingerprinted); under sampling only a subset is, and dividing by
---the true call count would silently deflate every share — "62 % of the
---calls actually examined shared this value" stays an honest claim either
---way, "6 % of all calls" would not (most of them were never looked at).
---@internal
---@param stats RA.Telemetry.ArgStats
---@return integer
local function fingerprint_total(stats)
  local total = stats.other or 0
  for _, n in pairs(stats.values or {}) do
    total = total + n
  end
  return total
end

---@internal
---@param stats RA.Telemetry.ArgStats
---@param total integer the fingerprint bucket's own total — see `fingerprint_total`
---@return { fingerprint: string, count: integer, share: number }[] top, integer other, integer distinct
local function top_fingerprints(stats, total)
  local list = {}
  for fp, n in pairs(stats.values or {}) do
    list[#list + 1] = { fingerprint = fp, count = n, share = total > 0 and n / total or 0 }
  end
  table.sort(list, function(a, b)
    if a.count == b.count then
      return a.fingerprint < b.fingerprint
    end
    return a.count > b.count
  end)
  return list, stats.other or 0, stats.distinct or 0
end

---Build the report for one instance's data.
---@param namespace string
---@param data RA.Telemetry.Data
---@param meta { running: boolean, disabled: boolean, wrapped: integer, modes: table }
---@param opts? RA.Telemetry.ReportOpts
---@return RA.Telemetry.Report
function M.build(namespace, data, meta, opts)
  opts = opts or {}

  local days = store.parse_since(opts.since)
  local windowed = days and store.since(data, days) or nil

  local entries, total = {}, 0
  for key, stats in pairs(data.functions or {}) do
    local calls = windowed and (windowed[key] or 0) or (stats.calls or 0)
    if calls > 0 or not windowed then
      local entry = { key = key, calls = calls, errors = stats.errors or 0 }

      local timing = stats.timing
      if timing and (timing.n or 0) > 0 then
        entry.mean_ms = timing.total_ms / timing.n
        entry.min_ms = timing.min_ms
        entry.max_ms = timing.max_ms
      end

      if stats.args then
        -- Argument shares are lifetime shares; the day buckets hold call
        -- counts only. Computing them against a windowed call count would
        -- produce percentages that do not add up, so use the lifetime
        -- total — specifically the fingerprint bucket's own total, not
        -- `stats.calls`, so §3.2 sampling (only some calls fingerprinted)
        -- never silently deflates every share — see `fingerprint_total`.
        local args_total = fingerprint_total(stats.args)
        local list, other, distinct = top_fingerprints(stats.args, args_total)
        entry.args, entry.other, entry.distinct = list, other, distinct

        -- `"()"` is the fingerprint of a zero-argument call. It is always
        -- 100 % dominant and never actionable — memoizing a function that
        -- takes no arguments is a different decision entirely. The
        -- min-calls guard against small-sample noise uses the same
        -- fingerprinted total the share itself does, for the identical
        -- sampling-honesty reason.
        local first = list[1]
        if
          first
          and first.fingerprint ~= "()"
          and args_total >= DOMINANT_MIN_CALLS
          and first.share >= DOMINANT_SHARE
        then
          entry.hint = ("%.0f %% of calls share one argument — candidate for %s"):format(
            first.share * 100,
            "memoization (lib.lua.memo.memo / .lru)"
          )
        end
      end

      if stats.error_fp then
        -- Share is of fingerprinted errors, not `errors` (the true error
        -- count) or `calls` — "62 % of errors were this one message" is
        -- the readable claim, and the fingerprint bucket's own total is
        -- what keeps it honest under §3.2 sampling too, same reasoning as
        -- the argument-profile block above.
        local list, other, distinct =
          top_fingerprints(stats.error_fp, fingerprint_total(stats.error_fp))
        entry.error_fp, entry.error_other, entry.error_distinct = list, other, distinct
      end

      if stats.callers then
        -- a caller site is a fingerprint exactly
        -- like an argument, just derived from `debug.getinfo` instead of
        -- the call's own arguments, so it reuses the identical bucket and
        -- the identical sampling-honest share calculation.
        local list, other, distinct =
          top_fingerprints(stats.callers, fingerprint_total(stats.callers))
        entry.callers, entry.callers_other, entry.callers_distinct = list, other, distinct
      end

      entries[#entries + 1] = entry
      total = total + calls
    end
  end

  local sort = opts.sort or "calls"
  table.sort(entries, function(a, b)
    if sort == "name" then
      return a.key < b.key
    elseif sort == "time" then
      return (a.mean_ms or -1) > (b.mean_ms or -1)
    end
    if a.calls == b.calls then
      return a.key < b.key
    end
    return a.calls > b.calls
  end)

  if opts.top and opts.top > 0 then
    for i = #entries, opts.top + 1, -1 do
      entries[i] = nil
    end
  end

  return {
    namespace = namespace,
    running = meta.running,
    disabled = meta.disabled,
    modes = meta.modes,
    wrapped = meta.wrapped,
    started_at = data.started_at,
    sessions = data.sessions or 0,
    total_calls = total,
    since = days and (days .. "d") or nil,
    info = data.info or {},
    entries = entries,
  }
end

---@param report RA.Telemetry.Report
---@return string[]
function M.lines(report)
  local out = {}

  local modes = {}
  if report.modes.args then
    modes[#modes + 1] = "args"
  end
  if report.modes.timing then
    modes[#modes + 1] = "timing"
  end
  if report.modes.errors then
    modes[#modes + 1] = "errors"
  end
  if report.modes.call_tree then
    modes[#modes + 1] = "call_tree"
  end
  local mode_str = #modes > 0 and ("counting + " .. table.concat(modes, " + ")) or "counting"

  -- `M.disable()` always stops a live instance before persisting, and
  -- `inst.start()` refuses to run while disabled, so "disabled" and
  -- "running" never overlap in practice.
  local state = report.disabled and "disabled" or (report.running and "running" or "stopped")
  out[#out + 1] = ("%s  —  %s"):format(report.namespace, state)
  out[#out + 1] = ("  %s · %s wrapped · %s calls · %d session(s)%s"):format(
    mode_str,
    num(report.wrapped),
    num(report.total_calls),
    report.sessions,
    report.since and (" · last " .. report.since) or ""
  )
  if report.started_at then
    out[#out + 1] = ("  collecting since %s"):format(os.date("%Y-%m-%d %H:%M", report.started_at))
  end
  local info_line = format_info(report.info)
  if info_line then
    out[#out + 1] = ("  %s"):format(info_line)
  end
  out[#out + 1] = ""

  if #report.entries == 0 then
    out[#out + 1] = "  (no calls recorded)"
    return out
  end

  local width = 0
  for _, e in ipairs(report.entries) do
    width = math.max(width, #e.key)
  end
  width = math.min(width, 46)

  for _, e in ipairs(report.entries) do
    local line = ("  %-" .. width .. "s %10s calls"):format(e.key:sub(1, width), num(e.calls))
    if e.mean_ms then
      line = line .. ("  %7.2fms avg (%.2f–%.2f)"):format(e.mean_ms, e.min_ms, e.max_ms)
    end
    if e.errors > 0 then
      line = line .. ("  %s error(s)"):format(num(e.errors))
    end
    out[#out + 1] = line

    if e.args then
      local shown = 0
      for _, a in ipairs(e.args) do
        shown = shown + 1
        if shown > ARGS_SHOWN then
          break
        end
        out[#out + 1] = ("      └ %3.0f %%  %s"):format(a.share * 100, a.fingerprint)
      end
      if (e.other or 0) > 0 then
        out[#out + 1] = ("      └ %3.0f %%  <other: %d distinct>"):format(
          e.calls > 0 and (e.other / e.calls * 100) or 0,
          e.distinct or 0
        )
      end
      if e.hint then
        out[#out + 1] = ("      ⓘ %s"):format(e.hint)
      end
    end

    if e.error_fp then
      local shown = 0
      for _, a in ipairs(e.error_fp) do
        shown = shown + 1
        if shown > ARGS_SHOWN then
          break
        end
        out[#out + 1] = ("      ✗ %3.0f %%  %s"):format(a.share * 100, a.fingerprint)
      end
      if (e.error_other or 0) > 0 then
        out[#out + 1] = ("      ✗ %3.0f %%  <other: %d distinct>"):format(
          e.errors > 0 and (e.error_other / e.errors * 100) or 0,
          e.error_distinct or 0
        )
      end
    end

    if e.callers then
      local shown = 0
      for _, a in ipairs(e.callers) do
        shown = shown + 1
        if shown > ARGS_SHOWN then
          break
        end
        out[#out + 1] = ("      ← %3.0f %%  %s"):format(a.share * 100, a.fingerprint)
      end
      if (e.callers_other or 0) > 0 then
        out[#out + 1] = ("      ← %3.0f %%  <other: %d distinct>"):format(
          e.calls > 0 and (e.callers_other / e.calls * 100) or 0,
          e.callers_distinct or 0
        )
      end
    end
  end

  return out
end

---Markdown rendering of the same report `M.lines` renders for the terminal.
---A separate function, not a flag on `M.lines`, because the two are shaped
---for different readers: `M.lines`'s box-drawing indentation and column
---padding are terminal artifacts that do not survive a Markdown renderer,
---and a GFM table is not `kit.viewer`-friendly either. Both build from the
---same `M.build()` result, so neither can drift from the other's numbers.
---@param report RA.Telemetry.Report
---@return string[]
function M.markdown(report)
  local out = {}

  local modes = {}
  if report.modes.args then
    modes[#modes + 1] = "args"
  end
  if report.modes.timing then
    modes[#modes + 1] = "timing"
  end
  if report.modes.errors then
    modes[#modes + 1] = "errors"
  end
  if report.modes.call_tree then
    modes[#modes + 1] = "call_tree"
  end
  local mode_str = #modes > 0 and ("counting + " .. table.concat(modes, " + ")) or "counting"

  local state = report.disabled and "disabled" or (report.running and "running" or "stopped")

  out[#out + 1] = ("# %s — telemetry"):format(report.namespace)
  out[#out + 1] = ""
  out[#out + 1] = ("**%s** · %s · %s wrapped · %s calls · %d session(s)%s"):format(
    state,
    mode_str,
    num(report.wrapped),
    num(report.total_calls),
    report.sessions,
    report.since and (" · last " .. report.since) or ""
  )
  if report.started_at then
    out[#out + 1] = ("Collecting since %s."):format(os.date("%Y-%m-%d %H:%M", report.started_at))
  end
  local info_line = format_info(report.info)
  if info_line then
    out[#out + 1] = ("_%s_"):format(info_line)
  end
  out[#out + 1] = ""

  if #report.entries == 0 then
    out[#out + 1] = "_(no calls recorded)_"
    return out
  end

  out[#out + 1] = "| Function | Calls | Ø ms | Errors |"
  out[#out + 1] = "| --- | ---: | ---: | ---: |"
  for _, e in ipairs(report.entries) do
    out[#out + 1] = ("| `%s` | %s | %s | %s |"):format(
      e.key,
      num(e.calls),
      e.mean_ms and ("%.2f"):format(e.mean_ms) or "—",
      e.errors > 0 and num(e.errors) or "—"
    )
  end

  -- Argument-profile subsections only for entries that actually have a
  -- profile, so a counting-only instance (the default) renders as one clean
  -- table and nothing else.
  for _, e in ipairs(report.entries) do
    if e.args then
      out[#out + 1] = ""
      out[#out + 1] = ("### `%s` — argument profile"):format(e.key)
      out[#out + 1] = ""
      out[#out + 1] = "| Share | Argument |"
      out[#out + 1] = "| ---: | --- |"

      local shown = 0
      for _, a in ipairs(e.args) do
        shown = shown + 1
        if shown > ARGS_SHOWN then
          break
        end
        out[#out + 1] = ("| %.0f %% | `%s` |"):format(a.share * 100, a.fingerprint)
      end
      if (e.other or 0) > 0 then
        out[#out + 1] = ("| %.0f %% | `<other: %d distinct>` |"):format(
          e.calls > 0 and (e.other / e.calls * 100) or 0,
          e.distinct or 0
        )
      end
      if e.hint then
        out[#out + 1] = ""
        out[#out + 1] = ("> **%s**"):format(e.hint)
      end
    end
  end

  -- Error-profile subsections, the identical shape as the argument-profile
  -- ones just above — a separate loop (not merged into it) so an entry
  -- with only one of the two profiles still renders exactly one section,
  -- in the same fixed order every report already has.
  for _, e in ipairs(report.entries) do
    if e.error_fp then
      out[#out + 1] = ""
      out[#out + 1] = ("### `%s` — error profile"):format(e.key)
      out[#out + 1] = ""
      out[#out + 1] = "| Share | Error |"
      out[#out + 1] = "| ---: | --- |"

      local shown = 0
      for _, a in ipairs(e.error_fp) do
        shown = shown + 1
        if shown > ARGS_SHOWN then
          break
        end
        out[#out + 1] = ("| %.0f %% | `%s` |"):format(a.share * 100, a.fingerprint)
      end
      if (e.error_other or 0) > 0 then
        out[#out + 1] = ("| %.0f %% | `<other: %d distinct>` |"):format(
          e.errors > 0 and (e.error_other / e.errors * 100) or 0,
          e.error_distinct or 0
        )
      end
    end
  end

  -- Call-tree subsections — the identical shape
  -- again, a separate loop for the same reason the error-profile one is.
  for _, e in ipairs(report.entries) do
    if e.callers then
      out[#out + 1] = ""
      out[#out + 1] = ("### `%s` — callers"):format(e.key)
      out[#out + 1] = ""
      out[#out + 1] = "| Share | Call site |"
      out[#out + 1] = "| ---: | --- |"

      local shown = 0
      for _, a in ipairs(e.callers) do
        shown = shown + 1
        if shown > ARGS_SHOWN then
          break
        end
        out[#out + 1] = ("| %.0f %% | `%s` |"):format(a.share * 100, a.fingerprint)
      end
      if (e.callers_other or 0) > 0 then
        out[#out + 1] = ("| %.0f %% | `<other: %d distinct>` |"):format(
          e.calls > 0 and (e.callers_other / e.calls * 100) or 0,
          e.callers_distinct or 0
        )
      end
    end
  end

  return out
end

---Combine several reports into one document — one `#` heading for the
---document, each report's own heading demoted to `##` so the result is a
---single well-formed Markdown file rather than several concatenated ones.
---@param reports RA.Telemetry.Report[]
---@return string[]
function M.markdown_all(reports)
  local out = { "# runtime-analysis.nvim — telemetry", "" }

  if #reports == 0 then
    out[#out + 1] = "_(no telemetry instances)_"
    return out
  end

  for i, report in ipairs(reports) do
    if i > 1 then
      out[#out + 1] = ""
      out[#out + 1] = "---"
      out[#out + 1] = ""
    end
    local section = M.markdown(report)
    section[1] = section[1]:gsub("^# ", "## ")
    vim.list_extend(out, section)
  end

  return out
end

-- ---------------------------------------------------------------------------
-- Comparison across time windows
-- ---------------------------------------------------------------------------

---@internal
---@param key string
---@param current integer
---@param previous integer
---@return RA.Telemetry.Comparison.Entry
local function comparison_entry(key, current, previous)
  local e = { key = key, current = current, previous = previous, delta = current - previous }
  if previous > 0 then
    e.delta_pct = (current - previous) / previous
  end
  return e
end

---Build a "this window vs the one before it" comparison — day buckets are
---already stored, so this is a report mode over existing data, not a
---collection change. Answers *what changed*, not just two totals side by
---side: which functions are newly hot (silent in the previous window,
---called in this one), which went cold (the reverse), and which simply
---moved (called in both, by how much).
---@param data RA.Telemetry.Data
---@param opts? { days?: integer, retention_days?: integer } `days` default 7;
---`retention_days` — when given, and `2 * days` exceeds it, the previous
---window may already be missing pruned buckets, and the result says so
---(`incomplete_previous_window`) rather than silently reporting a window
---that is actually shorter than `days`.
---@return RA.Telemetry.Comparison
function M.compare(data, opts)
  opts = opts or {}
  local days = opts.days or 7

  local current, current_total = store.since(data, days)
  local previous, previous_total = store.previous_window(data, days)

  local keys = {}
  for key in pairs(current) do
    keys[key] = true
  end
  for key in pairs(previous) do
    keys[key] = true
  end

  local new_functions, cold_functions, changed = {}, {}, {}
  for key in pairs(keys) do
    local c, p = current[key] or 0, previous[key] or 0
    if p == 0 then
      -- c must be > 0 here: a key with both counts 0 is never in `keys`.
      new_functions[#new_functions + 1] = comparison_entry(key, c, p)
    elseif c == 0 then
      cold_functions[#cold_functions + 1] = comparison_entry(key, c, p)
    else
      changed[#changed + 1] = comparison_entry(key, c, p)
    end
  end

  table.sort(new_functions, function(a, b)
    return a.current > b.current
  end)
  table.sort(cold_functions, function(a, b)
    return a.previous > b.previous
  end)
  table.sort(changed, function(a, b)
    return math.abs(a.delta) > math.abs(b.delta)
  end)

  return {
    days = days,
    current_total = current_total,
    previous_total = previous_total,
    new_functions = new_functions,
    cold_functions = cold_functions,
    changed = changed,
    incomplete_previous_window = opts.retention_days ~= nil and (days * 2) > opts.retention_days,
  }
end

---@param cmp RA.Telemetry.Comparison
---@return string[]
function M.compare_lines(cmp)
  local out = {}
  out[#out + 1] = ("last %dd vs the %dd before that  —  %s calls vs %s calls"):format(
    cmp.days,
    cmp.days,
    num(cmp.current_total),
    num(cmp.previous_total)
  )
  if cmp.incomplete_previous_window then
    out[#out + 1] =
      "  ⚠ retention_days is shorter than 2× this window — the previous window may already be missing pruned data"
  end
  out[#out + 1] = ""

  if #cmp.new_functions == 0 and #cmp.cold_functions == 0 and #cmp.changed == 0 then
    out[#out + 1] = "  (no calls recorded in either window)"
    return out
  end

  if #cmp.new_functions > 0 then
    out[#out + 1] = "  newly hot:"
    for _, e in ipairs(cmp.new_functions) do
      out[#out + 1] = ("    + %-40s %s calls (silent before)"):format(e.key, num(e.current))
    end
    out[#out + 1] = ""
  end

  if #cmp.cold_functions > 0 then
    out[#out + 1] = "  went cold:"
    for _, e in ipairs(cmp.cold_functions) do
      out[#out + 1] = ("    - %-40s was %s calls, silent now"):format(e.key, num(e.previous))
    end
    out[#out + 1] = ""
  end

  if #cmp.changed > 0 then
    out[#out + 1] = "  changed:"
    for _, e in ipairs(cmp.changed) do
      local arrow = e.delta >= 0 and "↑" or "↓"
      local sign = e.delta >= 0 and "+" or ""
      out[#out + 1] = ("    %s %-40s %s -> %s calls (%s%.0f %%)"):format(
        arrow,
        e.key,
        num(e.previous),
        num(e.current),
        sign,
        e.delta_pct * 100
      )
    end
  end

  return out
end

---@param cmp RA.Telemetry.Comparison
---@return string[]
function M.compare_markdown(cmp)
  local out = {
    ("# last %dd vs the %dd before that"):format(cmp.days, cmp.days),
    "",
    ("**%s calls** vs **%s calls**"):format(num(cmp.current_total), num(cmp.previous_total)),
  }
  if cmp.incomplete_previous_window then
    out[#out + 1] = ""
    out[#out + 1] =
      "> ⚠ `retention_days` is shorter than 2× this window — the previous window may already be missing pruned data."
  end
  out[#out + 1] = ""

  if #cmp.new_functions == 0 and #cmp.cold_functions == 0 and #cmp.changed == 0 then
    out[#out + 1] = "_(no calls recorded in either window)_"
    return out
  end

  if #cmp.new_functions > 0 then
    out[#out + 1] = "## Newly hot"
    out[#out + 1] = ""
    out[#out + 1] = "| Function | Calls |"
    out[#out + 1] = "| --- | ---: |"
    for _, e in ipairs(cmp.new_functions) do
      out[#out + 1] = ("| `%s` | %s |"):format(e.key, num(e.current))
    end
    out[#out + 1] = ""
  end

  if #cmp.cold_functions > 0 then
    out[#out + 1] = "## Went cold"
    out[#out + 1] = ""
    out[#out + 1] = "| Function | Was |"
    out[#out + 1] = "| --- | ---: |"
    for _, e in ipairs(cmp.cold_functions) do
      out[#out + 1] = ("| `%s` | %s |"):format(e.key, num(e.previous))
    end
    out[#out + 1] = ""
  end

  if #cmp.changed > 0 then
    out[#out + 1] = "## Changed"
    out[#out + 1] = ""
    out[#out + 1] = "| Function | Before | After | Change |"
    out[#out + 1] = "| --- | ---: | ---: | ---: |"
    for _, e in ipairs(cmp.changed) do
      local sign = e.delta >= 0 and "+" or ""
      out[#out + 1] = ("| `%s` | %s | %s | %s%.0f %% |"):format(
        e.key,
        num(e.previous),
        num(e.current),
        sign,
        e.delta_pct * 100
      )
    end
  end

  return out
end

---Compare two named snapshots' function call counts directly against each
---other — distinct from `M.compare`, which reads one continuously-
---accumulating dataset's own day buckets ("this week vs last week"). A
---snapshot is a deliberate point-in-time capture with no day buckets of its
---own worth trusting for this (`M.snapshot`'s doc-comment: it captures
---whatever `Data.days` happened to hold at that moment, not a clean window)
---— so this reads `Data.functions[key].calls` (lifetime totals as of each
---capture) instead, which is the one number every snapshot always has.
---
---**Classification reads the A→B *delta*, not raw totals — deliberately.**
---`calls` is a lifetime counter that only ever grows, so for two
---chronologically-ordered snapshots `b.calls` is always `>= a.calls` for
---any key already present at A (barring a `reset()` in between). Bucketing
---on raw totals the way `M.compare` does (which reads already-windowed,
---already-reset-per-window counts from day buckets — a different kind of
---number) would leave `cold_functions` structurally empty for the entire
---lifetime of a namespace: "silent since A" can never happen when a
---function's own count cannot go back down. Bucketing on `b.calls - a.calls`
---instead answers the question a caller comparing two checkpoints actually
---has — "did this get exercised across my test", not "has it EVER been
---exercised" — and is stable however long the namespace has already run
---before `name_a` was ever taken.
---@param namespace string
---@param name_a string  Label for `data_a` — conventionally the earlier one.
---@param name_b string  Label for `data_b` — conventionally the later one.
---@param data_a RA.Telemetry.Data
---@param data_b RA.Telemetry.Data
---@return RA.Telemetry.SnapshotComparison
function M.compare_snapshots(namespace, name_a, name_b, data_a, data_b)
  local a_functions, b_functions = data_a.functions or {}, data_b.functions or {}

  local keys = {}
  for key in pairs(a_functions) do
    keys[key] = true
  end
  for key in pairs(b_functions) do
    keys[key] = true
  end

  local new_functions, cold_functions, changed = {}, {}, {}
  local total_a, total_b = 0, 0
  for key in pairs(keys) do
    local a = (a_functions[key] and a_functions[key].calls) or 0
    local b = (b_functions[key] and b_functions[key].calls) or 0
    total_a, total_b = total_a + a, total_b + b
    local delta = b - a
    if a == 0 then
      -- No history at all before `name_a` — genuinely new, not just quiet
      -- this period. `b` must be > 0 here: a key with both counts 0 is
      -- never in `keys`.
      new_functions[#new_functions + 1] = comparison_entry(key, b, a)
    elseif delta == 0 then
      -- Had history before `name_a`, but zero calls happened between the
      -- two snapshots — "went cold" for THIS period, not "never called".
      cold_functions[#cold_functions + 1] = comparison_entry(key, b, a)
    else
      changed[#changed + 1] = comparison_entry(key, b, a)
    end
  end

  table.sort(new_functions, function(x, y)
    return x.current > y.current
  end)
  table.sort(cold_functions, function(x, y)
    return x.previous > y.previous
  end)
  table.sort(changed, function(x, y)
    return math.abs(x.delta) > math.abs(y.delta)
  end)

  return {
    namespace = namespace,
    name_a = name_a,
    name_b = name_b,
    total_a = total_a,
    total_b = total_b,
    new_functions = new_functions,
    cold_functions = cold_functions,
    changed = changed,
  }
end

---@param cmp RA.Telemetry.SnapshotComparison
---@return string[]
function M.compare_snapshots_lines(cmp)
  local out = {}
  out[#out + 1] = ("%s: %q vs %q  —  %s calls vs %s calls"):format(
    cmp.namespace,
    cmp.name_a,
    cmp.name_b,
    num(cmp.total_a),
    num(cmp.total_b)
  )
  out[#out + 1] = ""

  if #cmp.new_functions == 0 and #cmp.cold_functions == 0 and #cmp.changed == 0 then
    out[#out + 1] = "  (no calls recorded in either snapshot)"
    return out
  end

  if #cmp.new_functions > 0 then
    out[#out + 1] = ("  newly hot (silent in %q):"):format(cmp.name_a)
    for _, e in ipairs(cmp.new_functions) do
      out[#out + 1] = ("    + %-40s %s calls"):format(e.key, num(e.current))
    end
    out[#out + 1] = ""
  end

  if #cmp.cold_functions > 0 then
    out[#out + 1] = ("  no new calls since %q:"):format(cmp.name_a)
    for _, e in ipairs(cmp.cold_functions) do
      out[#out + 1] = ("    - %-40s %s calls total, none new"):format(e.key, num(e.previous))
    end
    out[#out + 1] = ""
  end

  if #cmp.changed > 0 then
    out[#out + 1] = "  changed:"
    for _, e in ipairs(cmp.changed) do
      local arrow = e.delta >= 0 and "↑" or "↓"
      local sign = e.delta >= 0 and "+" or ""
      local pct = e.delta_pct and (("%s%.0f %%"):format(sign, e.delta_pct * 100)) or "n/a"
      out[#out + 1] = ("    %s %-40s %s -> %s calls (%s)"):format(
        arrow,
        e.key,
        num(e.previous),
        num(e.current),
        pct
      )
    end
  end

  return out
end

---@param cmp RA.Telemetry.SnapshotComparison
---@return string[]
function M.compare_snapshots_markdown(cmp)
  local out = {
    ("# %s — %q vs %q"):format(cmp.namespace, cmp.name_a, cmp.name_b),
    "",
    ("**%s calls** vs **%s calls**"):format(num(cmp.total_a), num(cmp.total_b)),
    "",
  }

  if #cmp.new_functions == 0 and #cmp.cold_functions == 0 and #cmp.changed == 0 then
    out[#out + 1] = "_(no calls recorded in either snapshot)_"
    return out
  end

  if #cmp.new_functions > 0 then
    out[#out + 1] = ("## Newly hot (silent in %q)"):format(cmp.name_a)
    out[#out + 1] = ""
    out[#out + 1] = "| Function | Calls |"
    out[#out + 1] = "| --- | ---: |"
    for _, e in ipairs(cmp.new_functions) do
      out[#out + 1] = ("| `%s` | %s |"):format(e.key, num(e.current))
    end
    out[#out + 1] = ""
  end

  if #cmp.cold_functions > 0 then
    out[#out + 1] = ("## No new calls since %q"):format(cmp.name_a)
    out[#out + 1] = ""
    out[#out + 1] = "| Function | Total (unchanged) |"
    out[#out + 1] = "| --- | ---: |"
    for _, e in ipairs(cmp.cold_functions) do
      out[#out + 1] = ("| `%s` | %s |"):format(e.key, num(e.previous))
    end
    out[#out + 1] = ""
  end

  if #cmp.changed > 0 then
    out[#out + 1] = "## Changed"
    out[#out + 1] = ""
    out[#out + 1] = ("| Function | %s | %s | Change |"):format(cmp.name_a, cmp.name_b)
    out[#out + 1] = "| --- | ---: | ---: | ---: |"
    for _, e in ipairs(cmp.changed) do
      local sign = e.delta >= 0 and "+" or ""
      local pct = e.delta_pct and (("%s%.0f %%"):format(sign, e.delta_pct * 100)) or "n/a"
      out[#out + 1] = ("| `%s` | %s | %s | %s |"):format(
        e.key,
        num(e.previous),
        num(e.current),
        pct
      )
    end
  end

  return out
end

M.DOMINANT_SHARE = DOMINANT_SHARE
M.DOMINANT_MIN_CALLS = DOMINANT_MIN_CALLS
M.num = num

return M
