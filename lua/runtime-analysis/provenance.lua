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
---   - **Anyone else's wrapper: inferred, not known.** There is no registry
---     for a third-party monkey-patch, so the only honest signal available
---     is `debug.getinfo`'s own source location — WHERE the function
---     currently sitting there was actually defined. That cannot say WHO
---     installed it or WHEN, only that a reader can compare it against
---     where they expected it to live and draw their own conclusion.

local registry = require("runtime-analysis.telemetry.registry")

local M = {}

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
    out[#out + 1] =
      ("  wrapped by runtime-analysis.telemetry: %s"):format(table.concat(info.telemetry.namespaces, ", "))
  else
    out[#out + 1] = "  not wrapped by runtime-analysis.telemetry"
  end

  if not info.source then
    out[#out + 1] = "  source location unavailable"
  elseif info.source.what == "C" then
    out[#out + 1] = "  defined in C (a built-in, or a C extension) — no Lua source location"
  else
    out[#out + 1] = ("  defined at %s:%d"):format(info.source.short_src, info.source.linedefined)
  end

  if not info.telemetry.wrapped then
    out[#out + 1] =
      "  (best-effort: this only knows about this plugin's own wraps — compare the source location above against where you expect this to live)"
  end

  return out
end

return M
