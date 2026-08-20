---@module 'runtime-analysis.provenance'
--- Wrapper provenance — docs/ROADMAP.md §5.2, the narrow, high-value slice
--- of §5.1 ("Runtime inspection — a second pillar") the roadmap entry says
--- should ship first. Given a dotted path — `"vim.notify"`,
--- `"lib.nvim.notify.create"` — says what's actually installed there right
--- now.
---
--- Between this plugin's own telemetry, `lib.nvim.system.proc_trace`, and
--- any number of plugins that monkey-patch `vim.notify`, a real Neovim
--- session accumulates wrappers, and "why is this function not the one in
--- the source" is a genuinely hard question today. Two different answers,
--- and this module is honest about which one it can actually give:
---
---   - **This plugin's own telemetry wrapper: exact.** `telemetry.registry`
---     is the one shared wrap layer every instance goes through, so it
---     genuinely knows every subscriber by name (`registry.info`).
---   - **`lib.nvim.system.proc_trace`: exact, and for a cheaper reason.**
---     It wraps four *known* paths and already publishes `is_active()`, so
---     asking it is a fact rather than an inference. No shared convention
---     was needed for this — see below.
---   - **Anyone else's wrapper: inferred, not known.** There is no registry
---     for a third-party monkey-patch, so the only honest signal available
---     is `debug.getinfo`'s own source location — WHERE the function
---     currently sitting there was actually defined. That cannot say WHO
---     installed it or WHEN, only that a reader can compare it against
---     where they expected it to live and draw their own conclusion.
---
--- ## The shared wrapper registry, and why there is none
---
--- `docs/IDEAS.md` §4.1 proposed one: an identifiable marker every installed
--- wrapper carries, in `lib.nvim`, so provenance could answer for all three
--- instances of this technique rather than one. **Decided against**, and the
--- reasons are worth keeping because they are the ones that would have to
--- stop being true for it to be worth revisiting.
---
--- **There is one consumer, and §4.2 next door is explicit that pushing work
--- down waits for a second.** `proc_trace` never asks who wrapped anything —
--- it wraps and restores. It would be a *producer* of registry entries, and
--- this module would still be the only thing reading them.
---
--- **The case that would justify it is the one a convention cannot reach.**
--- The genuinely hard question is a third-party plugin monkey-patching
--- `vim.notify`; a convention in `lib.nvim` does not reach a plugin that has
--- never heard of `lib.nvim`. So the registry would have made the two
--- wrappers this ecosystem already controls exact, and left the hard case
--- exactly where it is.
---
--- **And those two did not need it.** The telemetry registry already answers
--- precisely, and `proc_trace` publishes enough to answer precisely, which
--- is what the branch below uses. A shared marker would have been a new
--- convention to buy something already reachable.
---
--- **What would reopen it:** a second consumer of "who wrapped this" — a
--- health check, or the desktop app asking across a session — or a wrapper
--- in this ecosystem that is *not* one of the two above and cannot publish
--- its own state.

local registry = require("runtime-analysis.telemetry.registry")

local M = {}

---The four paths `lib.nvim.system.proc_trace` wraps while it is running.
---
---Named here rather than asked for, because `proc_trace` publishes *whether*
---it is active and not *what* it took — and adding an accessor over there to
---avoid four strings here would be pushing work down for one consumer, which
---is exactly what `docs/IDEAS.md` §4.2 argues against.
---
---Written as a set of the dotted paths this module already resolves, so the
---comparison is against the reader's own input rather than against a
---container/field pair reconstructed from it.
---@type table<string, true>
local PROC_TRACE_PATHS = {
  ["vim.fn.system"] = true,
  ["vim.fn.systemlist"] = true,
  ["vim.system"] = true,
  ["vim.fn.jobstart"] = true,
}

---Whether `proc_trace` is currently wrapping `path`.
---
---**An exact answer where there used to be an inference.** Before this, a
---reader who had started `proc_trace` and then asked about `vim.fn.system`
---was told only where the function currently there was defined — a
---`lib.nvim` source path they then had to interpret. The module knows, and
---says so.
---
---Soft: `lib.nvim` is a hard dependency of this plugin, but a build of it
---without `system.proc_trace` is not this module's business to fail over.
---@param path string The dotted path as the reader typed it.
---@return boolean
local function proc_trace_wraps(path)
  if not PROC_TRACE_PATHS[path] then
    return false
  end
  local ok, trace = pcall(require, "lib.nvim.system.proc_trace")
  if not ok or type(trace.is_active) ~= "function" then
    return false
  end
  local ok_active, active = pcall(trace.is_active)
  return ok_active and active == true
end

---Resolve a dotted path's *container* (everything before the final field).
---Two strategies, tried in order — a global-table walk first (the common
---case for `"vim.notify"`-style targets), then `require()` of the whole
---prefix (the common case for a `lib.nvim`-style module field). Neither
---attempts anything past that: a container path that is itself nested past
---a module boundary (`a.b.c.field`, where `c` is a table field *of* module
---`a.b`, not a `require()`-able path of its own) has to be named with the
---real module prefix — guessing where that boundary sits would be exactly
---the kind of wrong guess `runtime-analysis.curl`'s own unrecognized-flag
---handling and `cost_vs_use`'s own module-root join both already refuse to
---make elsewhere in this plugin.
---@internal
---@param container_path string
---@return table? container
---@return "global"|"module"|nil kind
local function resolve_container(container_path)
  local ok_global, global_container = pcall(function()
    local cur = _G
    for part in container_path:gmatch("[^.]+") do
      if type(cur) ~= "table" then
        return nil
      end
      cur = cur[part]
    end
    return cur
  end)
  if ok_global and type(global_container) == "table" then
    return global_container, "global"
  end

  local ok_require, mod = pcall(require, container_path)
  if ok_require and type(mod) == "table" then
    return mod, "module"
  end

  return nil, nil
end

---@param path string dotted path, e.g. `"vim.notify"` or `"lib.nvim.notify.create"`
---@return { path: string, container_path: string, container_kind: "global"|"module", field: string, telemetry: { wrapped: boolean, namespaces: string[] }, source: { what: string, short_src: string, linedefined: integer }? }? info
---@return string? err
function M.inspect(path)
  local container_path, field = path:match("^(.+)%.([^.]+)$")
  if not container_path then
    return nil, ("%q has no '.' — expected CONTAINER.field, e.g. \"vim.notify\""):format(path)
  end

  local container, kind = resolve_container(container_path)
  if not container then
    return nil,
      ("could not resolve %q as either a global table path or a require()-able module"):format(
        container_path
      )
  end

  local value = container[field]
  if value == nil then
    return nil, ("%q has no field %q"):format(container_path, field)
  end
  if type(value) ~= "function" then
    return nil, ("%s.%s is a %s, not a function"):format(container_path, field, type(value))
  end

  local telemetry_info = registry.info(container, field)
  local proc_trace_owns = proc_trace_wraps(path)

  -- `debug.getinfo` on an arbitrary function never errors in practice, but
  -- this plugin's own conventions elsewhere (fs.read, curl.parse, ...)
  -- treat "should not fail" as still worth a `pcall` at a boundary this
  -- explicit, rather than trusting it implicitly.
  local ok_info, dbg = pcall(debug.getinfo, value, "S")
  local source = nil
  if ok_info and dbg then
    source = { what = dbg.what, short_src = dbg.short_src, linedefined = dbg.linedefined }
  end

  return {
    path = path,
    container_path = container_path,
    container_kind = kind,
    field = field,
    telemetry = telemetry_info,
    proc_trace = proc_trace_owns,
    source = source,
  },
    nil
end

---@param info table `M.inspect`'s own return
---@return string[]
function M.lines(info)
  local out = {}
  out[#out + 1] = ("%s (resolved via %s %q)"):format(
    info.path,
    info.container_kind == "global" and "global table" or "require()",
    info.container_path
  )

  if info.telemetry.wrapped then
    out[#out + 1] = ("  wrapped by runtime-analysis.telemetry: %s"):format(
      table.concat(info.telemetry.namespaces, ", ")
    )
  else
    out[#out + 1] = "  not wrapped by runtime-analysis.telemetry"
  end

  -- Stated only when true. "not wrapped by proc_trace" on every one of the
  -- dozens of paths it never touches would be a line that is right and
  -- useless, and this report is read a line at a time.
  if info.proc_trace then
    out[#out + 1] = "  wrapped by lib.nvim.system.proc_trace (stop it with proc_trace.stop())"
  end

  if not info.source then
    out[#out + 1] = "  source location unavailable"
  elseif info.source.what == "C" then
    out[#out + 1] = "  defined in C (a built-in, or a C extension) — no Lua source location"
  else
    out[#out + 1] = ("  defined at %s:%d"):format(info.source.short_src, info.source.linedefined)
  end

  -- **The caveat is skipped once something *did* answer exactly**, and this
  -- condition had to widen the moment `proc_trace` became a second exact
  -- source. Left as it was, a reader shown "wrapped by proc_trace" would
  -- have been told in the next line that nothing here knows about wraps
  -- other than this plugin's — a sentence contradicted by the one above it.
  if not info.telemetry.wrapped and not info.proc_trace then
    out[#out + 1] = "  (best-effort: nothing here knows who installed this. Two wrappers "
      .. "can be named exactly — this plugin's telemetry and "
      .. "lib.nvim.system.proc_trace — and neither is on this one. Compare the "
      .. "source location above against where you expect this to live.)"
  end

  return out
end

return M
