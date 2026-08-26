---@module 'runtime-analysis.telemetry.startup'
--- Startup attribution — docs/ROADMAP.md §3.3. Which *module* a plugin's
--- startup cost actually sits in, as a waterfall.
---
--- **The roadmap entry's own premise needed correcting before this could be
--- built, and the correction is the interesting part.** It claimed "the lazy
--- adapter already knows exactly when each plugin loads, which is half the
--- mechanism." Half true: lazy.nvim's `loader._load` does time each plugin
--- (`plugin._.loaded.time`, and `Util._profiles`' nested tree), and that is
--- exactly the number the entry itself says is *not* the value here —
--- "lazy.nvim already reports its own numbers, so the value here is
--- specifically *within* a plugin." Checked directly against lazy.nvim's own
--- source rather than assumed: it does **not** time individual `require`s.
--- Its module loader (`loader.M.loader`) resolves and `loadfile`s a module
--- with no timing around it at all; the only nested `Util.track` calls are
--- for `source`ing vim files and for whole plugins. So the per-module half
--- has to come from somewhere else entirely, and the `User LazyLoad` autocmd
--- the existing `telemetry.lazy` adapter hooks is the wrong instrument twice
--- over: it fires *after* `config()` has already run (too late to measure
--- it) and it is per-plugin, not per-module.
---
--- What actually works: wrap the global `require` and time every **cache
--- miss** — an actual module load, not a `package.loaded` hit, which costs
--- nothing and is not a load at all. Nesting falls out naturally from a
--- stack: a module's *self* time is its total minus everything it required
--- in turn, which is what makes the result a waterfall rather than a list
--- where every parent double-counts its children.
---
--- Deliberately not part of a `telemetry.new()` instance: this measures
--- module loads, not function calls, has no namespace, no persistence and no
--- day buckets, and is over by the time the UI is up. Folding it into an
--- instance would mean four unused fields on every report that never has
--- startup data.

local M = {}

--- Recorded loads, in completion order.
---@type RA.Telemetry.Startup.Entry[]
local entries = {}

--- modname -> entry, so a nested load can be attributed to its parent
--- without a second scan.
---@type table<string, RA.Telemetry.Startup.Entry>
local by_name = {}

--- The currently-loading chain. Its top is whichever module's own `require`
--- call triggered the load now starting, which is how a child's cost is
--- subtracted from its parent's self time.
---@type RA.Telemetry.Startup.Entry[]
local stack = {}

--- The real `require`, captured on `start()`. Typed (and initialized) as a
--- function rather than left `nil` until then: assigning a `function|nil`
--- back to `_G.require` in `stop()` narrows the *global* `require`'s own
--- inferred type for every file in the project, which turns one local's
--- nilability into repo-wide false diagnostics at every `pcall(require, …)`
--- call site.
---@type fun(modname: string): any
local original_require = require
local running = false

local uv = vim.uv or vim.loop

---Wrap the global `require` and start timing every cache miss. Idempotent.
---
---Call this as early as possible — the honest limit stated plainly, since a
---startup profiler that hides it is worse than useless: **only modules
---required *after* this runs are ever seen.** Everything already in
---`package.loaded` by then (this plugin included, and on a real config
---quite a lot besides) is invisible, not zero-cost.
---@return boolean started
function M.start()
  if running then
    return false
  end
  original_require = require
  running = true

  _G.require = function(modname)
    -- A cache hit is not a load: it costs a table index, it is not
    -- attributable to anyone's startup, and recording it would bury the
    -- real loads under thousands of no-ops.
    if package.loaded[modname] ~= nil then
      return original_require(modname)
    end

    local entry = by_name[modname]
    if not entry then
      entry = { modname = modname, total_ms = 0, self_ms = 0, depth = #stack }
      by_name[modname] = entry
      entries[#entries + 1] = entry
    end

    stack[#stack + 1] = entry
    local t0 = uv.hrtime()

    -- `pcall`, not a bare call: a module that raises during load must not
    -- leave `stack` unbalanced, or every subsequent module's own self time
    -- is attributed to a parent that already finished. The error is
    -- re-raised verbatim afterwards, so this stays invisible to the caller.
    local ok, result = pcall(original_require, modname)

    local elapsed = (uv.hrtime() - t0) / 1e6
    stack[#stack] = nil

    entry.total_ms = entry.total_ms + elapsed
    entry.self_ms = entry.self_ms + elapsed
    -- Subtract this load's whole cost from whoever required it: the parent's
    -- own `self_ms` must not include time spent inside its children.
    local parent = stack[#stack]
    if parent then
      parent.self_ms = parent.self_ms - elapsed
    end

    if not ok then
      entry.errored = true
      error(result, 0)
    end
    return result
  end

  return true
end

---Restore the original `require`. Keeps everything recorded so far —
---`M.report()` stays readable after this, which is the normal case (stop at
---`UIEnter`, read the report whenever).
---@return boolean stopped
function M.stop()
  if not running then
    return false
  end
  _G.require = original_require
  running = false
  return true
end

---@return boolean
function M.is_running()
  return running
end

---Discard everything recorded. Does not stop timing.
function M.reset()
  entries = {}
  by_name = {}
  stack = {}
end

---The `.`-separated root of a module name — `"foo"` for `"foo.bar.baz"`.
---A plugin's own Lua namespace, which is what "which plugin" means here
---without needing to resolve a real path or ask a plugin manager: a
---dependency-free grouping this module can compute on its own, and the same
---one a reader already thinks in.
---@internal
---@param modname string
---@return string
local function root_of(modname)
  return (modname:match("^([^.]+)") or modname)
end

---Everything recorded, plus per-root totals — the waterfall
---docs/ROADMAP.md §3.3 asks for.
---@param opts? { top?: integer, sort?: "self"|"total"|"name" } `sort`
---defaults to `"self"`: "where did the time actually go" is the question
---this exists to answer, and total time re-orders by how deep a module sits
---in the require graph rather than by what it cost.
---@return RA.Telemetry.Startup.Report
function M.report(opts)
  opts = opts or {}

  local list = {}
  local roots, total_ms = {}, 0
  for _, e in ipairs(entries) do
    list[#list + 1] = e
    total_ms = total_ms + e.self_ms
    local root = root_of(e.modname)
    roots[root] = (roots[root] or 0) + e.self_ms
  end

  local sort = opts.sort or "self"
  table.sort(list, function(a, b)
    if sort == "name" then
      return a.modname < b.modname
    elseif sort == "total" then
      return a.total_ms > b.total_ms
    end
    if a.self_ms == b.self_ms then
      return a.modname < b.modname
    end
    return a.self_ms > b.self_ms
  end)

  local root_list = {}
  for name, ms in pairs(roots) do
    root_list[#root_list + 1] = { root = name, self_ms = ms }
  end
  table.sort(root_list, function(a, b)
    if a.self_ms == b.self_ms then
      return a.root < b.root
    end
    return a.self_ms > b.self_ms
  end)

  if opts.top and opts.top > 0 then
    for i = #list, opts.top + 1, -1 do
      list[i] = nil
    end
  end

  return {
    running = running,
    total_ms = total_ms,
    modules = list,
    roots = root_list,
  }
end

---@param report RA.Telemetry.Startup.Report
---@return string[]
function M.lines(report)
  local out = {}
  out[#out + 1] = ("startup attribution  —  %s"):format(
    report.running and "collecting" or "stopped"
  )
  out[#out + 1] = ("  %d module(s) loaded · %.1f ms total"):format(
    #report.modules,
    report.total_ms
  )
  out[#out + 1] = ""

  if #report.modules == 0 then
    out[#out + 1] = "  (nothing recorded — start() must run before the modules you want to see)"
    return out
  end

  out[#out + 1] = "  by plugin (module root), self time:"
  for _, r in ipairs(report.roots) do
    out[#out + 1] = ("    %-30s %8.2f ms"):format(r.root, r.self_ms)
  end
  out[#out + 1] = ""

  out[#out + 1] = "  by module, self time (total in parentheses):"
  for _, e in ipairs(report.modules) do
    out[#out + 1] = ("    %-40s %8.2f ms  (%.2f)%s"):format(
      e.modname:sub(1, 40),
      e.self_ms,
      e.total_ms,
      e.errored and "  ✗ raised" or ""
    )
  end

  return out
end

---@param report RA.Telemetry.Startup.Report
---@return string[]
function M.markdown(report)
  local out = {
    "# startup attribution",
    "",
    ("**%d module(s)** loaded · **%.1f ms** total · %s"):format(
      #report.modules,
      report.total_ms,
      report.running and "collecting" or "stopped"
    ),
    "",
  }

  if #report.modules == 0 then
    out[#out + 1] = "_(nothing recorded — `start()` must run before the modules you want to see)_"
    return out
  end

  out[#out + 1] = "## By plugin (module root)"
  out[#out + 1] = ""
  out[#out + 1] = "| Root | Self ms |"
  out[#out + 1] = "| --- | ---: |"
  for _, r in ipairs(report.roots) do
    out[#out + 1] = ("| `%s` | %.2f |"):format(r.root, r.self_ms)
  end
  out[#out + 1] = ""

  out[#out + 1] = "## By module"
  out[#out + 1] = ""
  out[#out + 1] = "| Module | Self ms | Total ms |"
  out[#out + 1] = "| --- | ---: | ---: |"
  for _, e in ipairs(report.modules) do
    out[#out + 1] = ("| `%s`%s | %.2f | %.2f |"):format(
      e.modname,
      e.errored and " ✗" or "",
      e.self_ms,
      e.total_ms
    )
  end

  return out
end

---Start now and stop automatically once the UI is up — the shape a real
---config wants, since startup is over by then and leaving the `require`
---wrapper installed for the rest of the session would keep paying for
---something with nothing left to measure.
---
---**Call this from this plugin's own lazy.nvim `init` function**, not from
---a line in `init.lua`: lazy.nvim runs every plugin's `init` in one pass
---*before* it loads any plugin at all (`loader.M.startup`, step 1 of 4), so
---that hook is both early enough and lives in the spec that declares the
---plugin — uninstalling removes it automatically. A line in `init.lua`
---would have to be removed by hand forever, because an uninstalled plugin
---runs no code and could never take it back out.
---@return boolean started
function M.autostart()
  if not M.start() then
    return false
  end
  require("lib.nvim.bindings.autocmd").create("UIEnter", function()
    M.stop()
  end, {
    once = true,
    group = require("lib.nvim.bindings.autocmd").group("runtime_analysis_startup", true),
    desc = "runtime-analysis.telemetry.startup: stop timing once startup is over",
  })
  return true
end

return M
