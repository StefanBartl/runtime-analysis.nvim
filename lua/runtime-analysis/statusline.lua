---@module 'runtime-analysis.statusline'
---@brief A statusline component: one traffic light for whether anything
--- instrumented looks unhealthy today.
---@description
--- Red when any instrumented function has errored, yellow when nothing has
--- errored but something is running noticeably slow, green when everything
--- looks fine — before reaching for `:RATelemetry` explicitly.
---
--- A plain Lua string with no dependency on any statusline plugin, and
--- `""` rather than an error on anything unexpected: a statusline is not
--- the place for a failure popup.
---
--- **Why it lives here.** It used to live in `ui.nvim`, 140 lines of it,
--- reaching in through this plugin's public facade to fold the numbers
--- into a colour. The facade was the right seam, but the *interpretation*
--- — what counts as slow, what "today" means, which glyph — is this
--- plugin's own opinion about its own data, and it sat in another
--- repository with no test here to hold it. Two siblings
--- (`sandbox.nvim`, `sessions.nvim`) already shipped their own component
--- with `ui.nvim` a thin adapter over it; this closes the gap
--- (cross-feature report, finding E).
---
--- **Honest limits.** "Today" means `Data.days[today]`: functions actually
--- called today. The error count and mean call time behind them are
--- *lifetime* figures, because telemetry aggregates calls rather than
--- timestamping each one. So a function that errored months ago and has
--- not been called since will not turn this red — it has to be called
--- again today to count. That is the closest honest proxy for "right now"
--- this data supports, and it is deliberately not dressed up as more.

local M = {}

--- Red — something errored today.
local ERROR_GLYPH = " \240\159\148\180 "
--- Yellow — no errors, but something is running noticeably slow.
local SLOW_GLYPH = " \240\159\159\161 "
--- Green — everything instrumented looks fine.
local OK_GLYPH = " \240\159\159\162 "

--- Above this lifetime mean call time, in ms, a function counts as slow.
local DEFAULT_SLOW_MEAN_MS = 50

--- A namespace with no live instance is read off disk, and a statusline
--- redraws on nearly every event. Short enough to stay "today", long
--- enough to absorb a redraw burst.
local DISK_TTL_SECONDS = 5

---@class RA.Statusline.Entry
---@field errors integer
---@field mean_ms number|nil

---@type table<string, { entries: RA.Statusline.Entry[], expires_at: integer }>
local disk_cache = {}

---Drop the on-disk read cache. Useful from a test, or after a flush.
---@return nil
function M.invalidate()
  disk_cache = {}
end

---@internal
---Fold one namespace's entries into the running verdict.
---@param entries RA.Statusline.Entry[]
---@param state { error: boolean, slow: boolean }
---@param slow_ms number
local function classify(entries, state, slow_ms)
  for _, e in ipairs(entries) do
    if (e.errors or 0) > 0 then
      state.error = true
    end
    if e.mean_ms and e.mean_ms > slow_ms then
      state.slow = true
    end
  end
end

---@internal
---Today's entries for a namespace with no live instance, read straight off
---disk (read-only, no flush) and filtered to the keys marked called today.
---@param telemetry table
---@param namespace string
---@param today string
---@return RA.Statusline.Entry[]
local function entries_from_disk(telemetry, namespace, today)
  local now = os.time()
  local cached = disk_cache[namespace]
  if cached and cached.expires_at > now then
    return cached.entries
  end

  local ok, data = pcall(telemetry.load, namespace)
  if not ok or not data then
    disk_cache[namespace] = { entries = {}, expires_at = now + DISK_TTL_SECONDS }
    return {}
  end

  local active = (data.days and data.days[today]) or {}
  local entries = {}
  for key in pairs(active) do
    local stats = data.functions and data.functions[key]
    if stats then
      local mean_ms = nil
      if stats.timing and (stats.timing.n or 0) > 0 then
        mean_ms = stats.timing.total_ms / stats.timing.n
      end
      entries[#entries + 1] = { errors = stats.errors or 0, mean_ms = mean_ms }
    end
  end

  disk_cache[namespace] = { entries = entries, expires_at = now + DISK_TTL_SECONDS }
  return entries
end

---@internal
---Today's entries for `namespace`, live instance or not.
---@param telemetry table
---@param namespace string
---@param today string
---@return RA.Statusline.Entry[]
local function entries_for(telemetry, namespace, today)
  local ok_inst, inst = pcall(telemetry.get, namespace)
  if ok_inst and inst then
    -- In-memory only (base + pending), never flushes, so this is safe to
    -- call on every render.
    local ok_report, report = pcall(inst.report, { since = "1d" })
    if ok_report and type(report) == "table" then
      return report.entries or {}
    end
    return {}
  end
  return entries_from_disk(telemetry, namespace, today)
end

---The traffic light, or `""` when there is nothing to watch.
---
---Empty when nothing has ever wrapped or started a telemetry instance: a
---light with no plugin behind it is not a signal, just clutter.
---@param opts? { slow_mean_ms?: number }
---@return string
function M.status(opts)
  local slow_ms = (opts and opts.slow_mean_ms) or DEFAULT_SLOW_MEAN_MS

  local ok_mod, telemetry = pcall(require, "runtime-analysis.telemetry")
  if not ok_mod or type(telemetry) ~= "table" then
    return ""
  end

  local ok_ns, namespaces = pcall(telemetry.known_namespaces)
  if not ok_ns or type(namespaces) ~= "table" or #namespaces == 0 then
    return ""
  end

  local today = os.date("%Y-%m-%d") --[[@as string]]
  local state = { error = false, slow = false }
  for _, namespace in ipairs(namespaces) do
    classify(entries_for(telemetry, namespace, today), state, slow_ms)
  end

  if state.error then
    return ERROR_GLYPH
  elseif state.slow then
    return SLOW_GLYPH
  end
  return OK_GLYPH
end

---`status` under the name a lualine spec reads naturally.
---@return string
function M.lualine_component()
  return M.status()
end

return M
