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

---A file size for `M.status_lines`' own "how much is actually on disk"
---column — three tiers only (B/KB/MB), because a namespace's own aggregate
---(counts, fingerprint buckets) realistically never reaches GB.
---@internal
---@param bytes integer
---@return string
local function format_bytes(bytes)
  if bytes >= 1024 * 1024 then
    return ("%.1f MB"):format(bytes / (1024 * 1024))
  elseif bytes >= 1024 then
    return ("%.1f KB"):format(bytes / 1024)
  end
  return ("%d B"):format(bytes)
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

---`report.modes` (the 5 booleans `M.build`'s `meta.modes` carries in) as the
---one word every renderer of a report shows next to its namespace —
---`M.lines`, `M.markdown` and `M.summary_lines` all called this same
---four-if block inline until they didn't; kept here once so the three can
---never render it differently.
---@internal
---@param modes { counting: boolean, args: boolean, timing: boolean, errors: boolean, call_tree: boolean }
---@return string
local function mode_str(modes)
  local parts = {}
  if modes.args then
    parts[#parts + 1] = "args"
  end
  if modes.timing then
    parts[#parts + 1] = "timing"
  end
  if modes.errors then
    parts[#parts + 1] = "errors"
  end
  if modes.call_tree then
    parts[#parts + 1] = "call_tree"
  end
  return #parts > 0 and ("counting + " .. table.concat(parts, " + ")) or "counting"
end

---The same modes, short enough to be a table column rather than a sentence —
---`counting + args + timing + errors + call_tree` is 45 cells, which is a
---third of the status board's whole width for a value most rows spell the
---same way. `mode_str` above stays the prose form every per-namespace header
---uses; this is the column form.
---@internal
---@param modes { counting: boolean, args: boolean, timing: boolean, errors: boolean, call_tree: boolean }
---@return string
local function mode_badge(modes)
  local parts = {}
  if modes.args then
    parts[#parts + 1] = "args"
  end
  if modes.timing then
    parts[#parts + 1] = "time"
  end
  if modes.errors then
    parts[#parts + 1] = "err"
  end
  if modes.call_tree then
    parts[#parts + 1] = "tree"
  end
  return #parts > 0 and ("count+" .. table.concat(parts, "+")) or "count"
end

---`M.disable()` always stops a live instance before persisting, and
---`inst.start()` refuses to run while disabled, so "disabled" and "running"
---never overlap in practice.
---@internal
---@param report RA.Telemetry.Report
---@return string
local function state_of(report)
  return report.disabled and "disabled" or (report.running and "running" or "stopped")
end

-- ---------------------------------------------------------------------------
-- Column layout
--
-- Every aligned table below (`M.status_lines`' fleet board, `M.lines`' own
-- per-function block) pads in *display cells* rather than bytes: a namespace
-- or an argument fingerprint can carry multi-byte characters, and `%-20s`
-- counts bytes, so one `·` in a cell used to shift that row's whole tail one
-- column left of every other row's.
-- ---------------------------------------------------------------------------

--- Two spaces between every pair of columns — the same gutter reposcope.nvim's
--- own status table uses, so two overviews from the same ecosystem do not
--- disagree about what a column break looks like.
local GAP = "  "

---@internal
---@param s string
---@param width integer
---@return string
local function ljust(s, width)
  local pad = width - vim.fn.strdisplaywidth(s)
  return pad > 0 and (s .. (" "):rep(pad)) or s
end

---@internal
---@param s string
---@param width integer
---@return string
local function rjust(s, width)
  local pad = width - vim.fn.strdisplaywidth(s)
  return pad > 0 and ((" "):rep(pad) .. s) or s
end

---Truncate to `width` display cells, marking the cut with an ellipsis. Cuts
---the tail: a namespace and a function key are both recognised by how they
---start.
---@internal
---@param s string
---@param width integer
---@return string
local function elide(s, width)
  if vim.fn.strdisplaywidth(s) <= width then
    return s
  end
  return vim.fn.strcharpart(s, 0, width - 1) .. "…"
end

---Join already-padded cells with the standard gutter, dropping trailing
---whitespace so a right-padded last column does not leave a ragged edge for
---`$`/visual selection to run into.
---@internal
---@param cells string[]
---@return string
local function join_cells(cells)
  return (table.concat(cells, GAP):gsub("%s+$", ""))
end

---The header block every per-namespace terminal view opens with —
---namespace/state, mode + counts, collecting-since, `info` — with no
---per-function entries. Split out of `M.lines` so `:RATelemetry status`
---(`M.status_lines`) can show one namespace per THREE-ish lines instead of
---its full function-by-function report; `M.lines` itself is unchanged,
---just this block plus the entries loop it always had.
---
---Deliberately produces the exact same header row `M.lines` always has —
---`("%s  —  %s"):format(report.namespace, state)` — so `command.lua`'s
---`header_namespace()`/`<CR>`-drilldown keeps working on a `status` row
---exactly the way it already does on a full report's own header.
---@param report RA.Telemetry.Report
---@return string[]
function M.summary_lines(report)
  local out = {}

  out[#out + 1] = ("%s  —  %s"):format(report.namespace, state_of(report))
  out[#out + 1] = ("  %s · %s wrapped · %s calls · %d session(s)%s"):format(
    mode_str(report.modes),
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
  return out
end

--- Widest a function key is allowed to get before it is elided. A key is a
--- module path plus a function name (`bindings.actions.next_heading`), and
--- letting the longest one in a plugin set the column pushes CALLS off the
--- right edge for every other row.
local MAX_KEY_W = 44

---@internal
---One fingerprint list (arguments, errors, callers) as indented sub-rows
---under the entry they belong to. All three render identically apart from
---their marker and label — they *are* the same shape (see `M.build`, which
---derives all three through `top_fingerprints`), so they were three
---near-identical loops until this.
---
---The label is what the marker alone never said: `└`/`✗`/`←` are only
---legible once you already know the report, and "which of the three lists
---is this" is the first question a reader has. Both are kept — the symbols
---because `renderers/html.lua` deliberately mirrors them, the word because
---it is the half that actually answers the question.
---@param out string[]
---@param marker string
---@param label string
---@param list { fingerprint: string, share: number }[]
---@param other integer|nil
---@param other_share number
---@param distinct integer|nil
local function push_fingerprints(out, marker, label, list, other, other_share, distinct)
  local shown = 0
  for _, a in ipairs(list) do
    shown = shown + 1
    if shown > ARGS_SHOWN then
      break
    end
    out[#out + 1] = ("    %s %-4s %3.0f %%  %s"):format(marker, label, a.share * 100, a.fingerprint)
  end

  -- The values this report KNOWS and simply did not print (`ARGS_SHOWN` caps
  -- the list at three). Distinct from the `<other>` row below, which is the
  -- values that were never kept in the first place (`max_arg_values`), and
  -- worth its own line rather than being folded into it: without one, three
  -- rows at 3 % each are all a reader sees of thirty recorded values, with
  -- nothing on screen saying the other twenty-seven exist.
  local rest_count, rest_share = 0, 0
  for i = ARGS_SHOWN + 1, #list do
    rest_count = rest_count + 1
    rest_share = rest_share + list[i].share
  end
  if rest_count > 0 then
    out[#out + 1] = ("    %s %-4s %3.0f %%  <%s more, not shown>"):format(
      marker,
      label,
      rest_share * 100,
      num(rest_count)
    )
  end

  if (other or 0) > 0 then
    out[#out + 1] = ("    %s %-4s %3.0f %%  <other: %s distinct>"):format(
      marker,
      label,
      other_share * 100,
      num(distinct or 0)
    )
  end
end

---@param report RA.Telemetry.Report
---@param opts? { data_path?: string, data_bytes?: integer }
---When given, one more header line naming the file this namespace's
---aggregate actually lives in, and how big it is. `:RATelemetry status`'s
---own drilldown passes it — "where exactly is this data" is a question the
---fleet board raises and only the per-namespace view has room to answer.
---@return string[]
function M.lines(report, opts)
  opts = opts or {}

  local out = M.summary_lines(report)
  if opts.data_path then
    out[#out + 1] = ("  %s · %s"):format(
      opts.data_bytes and format_bytes(opts.data_bytes) or "no data on disk",
      opts.data_path
    )
  end
  out[#out + 1] = ""

  if #report.entries == 0 then
    out[#out + 1] = "  (no calls recorded)"
    return out
  end

  -- Which optional columns this particular report has anything to put in.
  -- A counting-only namespace rendering an empty Ø MS column, or a column of
  -- "—" under ERRORS, is a third of the table's width spent saying "no".
  local any_timing, any_errors = false, false
  for _, e in ipairs(report.entries) do
    any_timing = any_timing or e.mean_ms ~= nil
    any_errors = any_errors or (e.errors or 0) > 0
  end

  local keys, calls, avgs, maxes, errs = {}, {}, {}, {}, {}
  local key_w, calls_w = #"FUNCTION", #"CALLS"
  local avg_w, max_w, err_w = #"Ø MS", #"MAX MS", #"ERRORS"
  for i, e in ipairs(report.entries) do
    keys[i] = elide(e.key, MAX_KEY_W)
    calls[i] = num(e.calls)
    avgs[i] = e.mean_ms and ("%.2f"):format(e.mean_ms) or "—"
    maxes[i] = e.max_ms and ("%.2f"):format(e.max_ms) or "—"
    errs[i] = (e.errors or 0) > 0 and num(e.errors) or "—"

    key_w = math.max(key_w, vim.fn.strdisplaywidth(keys[i]))
    calls_w = math.max(calls_w, #calls[i])
    avg_w = math.max(avg_w, #avgs[i])
    max_w = math.max(max_w, #maxes[i])
    err_w = math.max(err_w, #errs[i])
  end

  ---One table row (and, given the headings, the header itself — so the
  ---headings can never sit over a different column than their values).
  ---@param key string
  ---@param call string
  ---@param avg string
  ---@param max string
  ---@param err string
  ---@return string
  local function row(key, call, avg, max, err)
    local cells = { "  " .. ljust(key, key_w), rjust(call, calls_w) }
    if any_timing then
      cells[#cells + 1] = rjust(avg, avg_w)
      cells[#cells + 1] = rjust(max, max_w)
    end
    if any_errors then
      cells[#cells + 1] = rjust(err, err_w)
    end
    return join_cells(cells)
  end

  local header = row("FUNCTION", "CALLS", "Ø MS", "MAX MS", "ERRORS")
  out[#out + 1] = header
  -- A rule under the headings, not `=`: `telemetry_spec.lua` asserts a report
  -- with no `Options.info` renders no `=` anywhere, which is how it tells an
  -- absent info line from an empty one.
  out[#out + 1] = "  " .. ("─"):rep(math.max(0, vim.fn.strdisplaywidth(header) - 2))

  for i, e in ipairs(report.entries) do
    local before = #out
    out[#out + 1] = row(keys[i], calls[i], avgs[i], maxes[i], errs[i])

    if e.args then
      push_fingerprints(
        out,
        "└",
        "args",
        e.args,
        e.other,
        e.calls > 0 and ((e.other or 0) / e.calls) or 0,
        e.distinct
      )
      if e.hint then
        out[#out + 1] = ("    ⓘ %s"):format(e.hint)
      end
    end

    if e.error_fp then
      push_fingerprints(
        out,
        "✗",
        "err",
        e.error_fp,
        e.error_other,
        e.errors > 0 and ((e.error_other or 0) / e.errors) or 0,
        e.error_distinct
      )
    end

    if e.callers then
      push_fingerprints(
        out,
        "←",
        "from",
        e.callers,
        e.callers_other,
        e.calls > 0 and ((e.callers_other or 0) / e.calls) or 0,
        e.callers_distinct
      )
    end

    -- A blank line only after an entry that actually grew sub-rows, and never
    -- after the last one. Without it a fingerprint list runs straight into the
    -- next function's own row and the two read as one block; with it after
    -- *every* entry, a counting-only report (no sub-rows at all) would be
    -- double-spaced for no reason.
    if #out > before + 1 and i < #report.entries then
      out[#out + 1] = ""
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

  local state = report.disabled and "disabled" or (report.running and "running" or "stopped")

  out[#out + 1] = ("# %s — telemetry"):format(report.namespace)
  out[#out + 1] = ""
  out[#out + 1] = ("**%s** · %s · %s wrapped · %s calls · %d session(s)%s"):format(
    state,
    mode_str(report.modes),
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

--- Widest a namespace is allowed to get in the status table before it is
--- elided, so one long name cannot push the numeric columns off the float.
local MAX_NS_W = 30

---`:RATelemetry status`'s own view — ONE ROW per namespace this plugin knows
---about, in an aligned table, not a paragraph each.
---
---**Why a table and not `M.summary_lines` per namespace** (which is what this
---was first built as): the question is comparative — which of forty
---namespaces is still running, which one is quietly the biggest on disk, which
---one has not collected anything since August. Answers to a comparative
---question have to line up in columns; four lines of prose per namespace is
---the same data in the one shape that cannot be scanned. The shape is
---deliberately reposcope.nvim's `:Reposcope status` — same two-space gutter,
---same heading row, same `<CR>`-the-row-under-the-cursor — because a reader
---moving between two overviews from the same ecosystem should not have to
---learn two tables.
---
---Line 1 is the heading row and the last line is the fleet summary; the rows
---in between each start with their namespace at column 0, which is what
---`command.lua`'s `status_namespace_at()` reads back for `<CR>`.
---@param rows RA.Telemetry.StatusRow[]
---@return string[]
function M.status_lines(rows)
  if #rows == 0 then
    return { "no telemetry namespaces known -- nothing has run or persisted yet." }
  end

  local dw = vim.fn.strdisplaywidth
  local cells = {}
  local w = {
    ns = #"NAMESPACE",
    state = #"STATE",
    mode = #"MODE",
    wrapped = #"WRAPPED",
    calls = #"CALLS",
    sessions = #"SESSIONS",
    size = #"SIZE",
    since = #"SINCE",
  }

  local total_calls, total_bytes, running, disabled = 0, 0, 0, 0
  for i, row in ipairs(rows) do
    local r = row.report
    cells[i] = {
      ns = elide(r.namespace, MAX_NS_W),
      state = state_of(r),
      mode = mode_badge(r.modes),
      wrapped = num(r.wrapped),
      calls = num(r.total_calls),
      sessions = num(r.sessions),
      size = row.data_bytes and format_bytes(row.data_bytes) or "—",
      -- Date only. The clock time a namespace happened to start collecting at
      -- is real detail, but it is per-namespace detail: `M.lines`' own header
      -- still carries it, and in a column it is eight cells of noise across
      -- every row.
      since = r.started_at and tostring(os.date("%Y-%m-%d", r.started_at)) or "—",
    }
    for key, value in pairs(cells[i]) do
      w[key] = math.max(w[key], dw(value))
    end

    total_calls = total_calls + (r.total_calls or 0)
    total_bytes = total_bytes + (row.data_bytes or 0)
    if r.running then
      running = running + 1
    end
    if r.disabled then
      disabled = disabled + 1
    end
  end

  ---@param c table<string, string>
  ---@return string
  local function line_of(c)
    return join_cells({
      ljust(c.ns, w.ns),
      ljust(c.state, w.state),
      ljust(c.mode, w.mode),
      rjust(c.wrapped, w.wrapped),
      rjust(c.calls, w.calls),
      rjust(c.sessions, w.sessions),
      rjust(c.size, w.size),
      c.since,
    })
  end

  local out = {
    line_of({
      ns = "NAMESPACE",
      state = "STATE",
      mode = "MODE",
      wrapped = "WRAPPED",
      calls = "CALLS",
      sessions = "SESSIONS",
      size = "SIZE",
      since = "SINCE",
    }),
  }
  for _, c in ipairs(cells) do
    out[#out + 1] = line_of(c)
  end

  out[#out + 1] = ""
  out[#out + 1] = ("%d namespace(s) · %d running · %d disabled · %s calls · %s on disk"):format(
    #rows,
    running,
    disabled,
    num(total_calls),
    format_bytes(total_bytes)
  )
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
