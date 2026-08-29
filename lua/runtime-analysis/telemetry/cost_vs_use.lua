---@module 'runtime-analysis.telemetry.cost_vs_use'
--- Plugin cost-versus-use — Combines
--- `runtime-analysis.telemetry.startup`'s per-module startup cost with a
--- telemetry instance's own call count into one number: what a plugin
--- costs to load versus how much it is actually used. "That is the report
--- that gets plugins deleted," per the roadmap entry's own framing.
---
--- **The join the roadmap entry treated as free turned out not to be.**
--- Both halves existed once §3.3 shipped, and the entry's own revised text
--- named the real obstacle: startup attribution groups by module *root* (a
--- plugin's own Lua namespace — `"markdown"` for `require("markdown.buffer")`);
--- telemetry groups by *namespace*, a caller-chosen label that is usually
--- the repo name (`"markdown.nvim"`), not the module name. The two are only
--- sometimes the same string, and guessing when they match — stripping
--- `".nvim"`, fuzzy comparison — would silently attribute one plugin's
--- startup cost to a different one on a name collision, which is a worse
--- failure than reporting nothing.
---
--- **The actual join needs no guessing at all.** A telemetry instance
--- already knows, for every function that resolves to a real module path
--- (`inst.resolved_modules()` — `wrap_loaded()` targets and any `wrap()`
--- call given an explicit `module_id`; see that function's own doc-comment
--- for exactly which functions qualify), which real modules its own calls
--- live in. Reading the module root off each of those real paths and
--- matching it against `startup`'s own per-root totals joins on the one
--- thing both features already track honestly: a real Lua module path, not
--- a name that merely looks similar.

local M = {}

---The `.`-separated root of a module name — mirrors
---`telemetry.startup`'s own `root_of`, duplicated rather than required:
---a three-line pure-string function, and pulling in `startup.lua` for it
---would be the wrong kind of coupling for what is otherwise a
---deliberately decoupled join (see the module doc-comment).
---@internal
---@param modname string
---@return string
local function root_of(modname)
  return (modname:match("^([^.]+)") or modname)
end

---@internal
---@param t table
---@return integer
local function count_keys(t)
  local n = 0
  for _ in pairs(t) do
    n = n + 1
  end
  return n
end

---Build one namespace's cost-vs-use entry.
---@param namespace string
---@param resolved_modules table<string, string> `inst.resolved_modules()` — key -> real module path
---@param total_calls integer `inst.report().total_calls`
---@param startup_report RA.Telemetry.Startup.Report
---@return RA.Telemetry.CostVsUse.Entry
function M.build(namespace, resolved_modules, total_calls, startup_report)
  local my_roots = {}
  for _, path in pairs(resolved_modules) do
    my_roots[root_of(path)] = true
  end
  local resolved_root_count = count_keys(my_roots)

  local self_ms_by_root = {}
  for _, r in ipairs(startup_report.roots) do
    self_ms_by_root[r.root] = r.self_ms
  end

  local matched_roots = {}
  local startup_ms = nil
  for root in pairs(my_roots) do
    if self_ms_by_root[root] then
      startup_ms = (startup_ms or 0) + self_ms_by_root[root]
      matched_roots[#matched_roots + 1] = root
    end
  end
  table.sort(matched_roots)

  -- Two different reasons `startup_ms` can be unknown, and a reader needs
  -- to tell them apart to know what to do about it: no resolvable module
  -- at all (this namespace never gave telemetry a real module path to
  -- work with — a plain `wrap(tbl, "label")` instance) versus resolvable
  -- modules that simply never showed up in startup's own data (startup
  -- attribution was not running, or they loaded before `autostart()`).
  local reason = nil
  if startup_ms == nil then
    reason = resolved_root_count == 0
        and "no real module path known for this namespace (wrap_loaded()/module_id never used)"
      or "known module(s), but none appear in the startup report (autostart() not running, or they loaded before it)"
  end

  return {
    namespace = namespace,
    total_calls = total_calls,
    startup_ms = startup_ms,
    matched_roots = matched_roots,
    resolved_root_count = resolved_root_count,
    calls_per_ms = (startup_ms and startup_ms > 0) and (total_calls / startup_ms) or nil,
    reason = reason,
  }
end

---Build every namespace's entry and sort with the roadmap entry's own
---stated purpose in mind: "the report that gets plugins deleted" needs the
---worst offenders — high cost, low use — first, not alphabetical order.
---Entries with unknown cost sort last (there is nothing to judge them by)
---rather than first or scattered through the middle.
---@param namespaces { namespace: string, resolved_modules: table<string,string>, total_calls: integer }[]
---@param startup_report RA.Telemetry.Startup.Report
---@return RA.Telemetry.CostVsUse.Entry[]
function M.build_all(namespaces, startup_report)
  local out = {}
  for _, n in ipairs(namespaces) do
    out[#out + 1] = M.build(n.namespace, n.resolved_modules, n.total_calls, startup_report)
  end

  table.sort(out, function(a, b)
    local a_known, b_known = a.startup_ms ~= nil, b.startup_ms ~= nil
    if a_known ~= b_known then
      return a_known
    end
    if not a_known then
      return a.namespace < b.namespace
    end
    local ar, br = a.calls_per_ms or 0, b.calls_per_ms or 0
    if ar == br then
      return a.namespace < b.namespace
    end
    return ar < br
  end)

  return out
end

---@internal
---@param n number
---@return string
local function num(n)
  local s = tostring(math.floor(n + 0.5))
  local out = s:reverse():gsub("(%d%d%d)", "%1 "):reverse()
  return (out:gsub("^%s+", ""))
end

---@param entries RA.Telemetry.CostVsUse.Entry[]
---@return string[]
function M.lines(entries)
  local out = {}
  out[#out + 1] = "cost vs. use — worst (expensive, underused) first"
  out[#out + 1] = ""

  if #entries == 0 then
    out[#out + 1] = "  (no telemetry instances)"
    return out
  end

  for _, e in ipairs(entries) do
    if e.startup_ms then
      out[#out + 1] = ("  %-30s %8.2f ms startup  %10s calls  (%.1f calls/ms)"):format(
        e.namespace,
        e.startup_ms,
        num(e.total_calls),
        e.calls_per_ms
      )
      out[#out + 1] = ("      matched module root(s): %s"):format(
        table.concat(e.matched_roots, ", ")
      )
    else
      out[#out + 1] = ("  %-30s %10s calls  — startup cost unknown"):format(
        e.namespace,
        num(e.total_calls)
      )
      out[#out + 1] = ("      %s"):format(e.reason)
    end
  end

  return out
end

---@param entries RA.Telemetry.CostVsUse.Entry[]
---@return string[]
function M.markdown(entries)
  local out = {
    "# runtime-analysis.nvim — cost vs. use",
    "",
    "Worst (expensive, underused) first.",
    "",
  }

  if #entries == 0 then
    out[#out + 1] = "_(no telemetry instances)_"
    return out
  end

  out[#out + 1] = "| Namespace | Startup ms | Calls | Calls/ms |"
  out[#out + 1] = "| --- | ---: | ---: | ---: |"
  for _, e in ipairs(entries) do
    out[#out + 1] = ("| `%s` | %s | %s | %s |"):format(
      e.namespace,
      e.startup_ms and ("%.2f"):format(e.startup_ms) or "unknown",
      num(e.total_calls),
      e.calls_per_ms and ("%.1f"):format(e.calls_per_ms) or "—"
    )
  end

  local any_unknown = false
  for _, e in ipairs(entries) do
    if e.startup_ms == nil then
      any_unknown = true
      break
    end
  end
  if any_unknown then
    out[#out + 1] = ""
    out[#out + 1] = "### Unknown startup cost"
    out[#out + 1] = ""
    for _, e in ipairs(entries) do
      if e.startup_ms == nil then
        out[#out + 1] = ("- `%s` — %s"):format(e.namespace, e.reason)
      end
    end
  end

  return out
end

return M
