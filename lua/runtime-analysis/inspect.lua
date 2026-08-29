---@module 'runtime-analysis.inspect'
--- `:RA inspect <module>` — walking a live
--- `package.loaded` table and rendering it: functions (with upvalue
--- counts and source location), nested tables (their own shape),
--- metatables, and what a direct key *shadows* through `__index`.
---
--- lib.nvim's own roadmap turned this down as `:LibInspect`, with a
--- precise reason — "actually executing/requiring code is a different
--- trust model than docmap's pure static scan" — and named a future tool
--- as the right home. This is that tool. `runtime-analysis.loaded`
--- (§5.3) already answers the flat, one-level question "what functions
--- does this module have right now"; this module answers the deeper one
--- a config author actually needs: what does this table *contain*, after
--- however many merge passes built it, and is anything here not what the
--- source alone would suggest.
---
--- **Three open design questions this module inherits from that
--- rejection, and how each is resolved:**
---
---   1. **Cycle and depth limits.** Cycle-*safety* comes from an
---      identity-keyed `seen` set tracking the current ancestor chain —
---      the same convention lib.nvim's own `lib.lua.tables.deep_copy`
---      already uses for the identical reason — which alone guarantees
---      termination on a live table with a real cycle in it. `max_depth`
---      (default 3) is a *separate*, purely cosmetic cap on top of that:
---      enough to see through this section's own motivating example ("a
---      config table after three merge passes"), not a correctness
---      mechanism the way `seen` is.
---   2. **`__index` is reported, never called.** A key present directly
---      on a table, when its metatable's `__index` is itself a table
---      that would also answer that key, is reported as *shadowing* it —
---      answerable by comparing keys, no invocation needed. When
---      `__index` is a function, nothing is reported beyond its
---      presence: calling it would be a real side effect on the very
---      code being inspected, and "reporting is honest but less useful"
---      is exactly the trade-off this repository has taken every other
---      time this question came up (`documentation.core.loaded_diff` and
---      `endpoint_coverage.lua`'s own "record it, don't guess it" rule).
---   3. **Renders via the same float every other report in this plugin
---      already uses** — `lib.nvim.ui.kit.viewer`, falling back to
---      `vim.notify` when kit is unavailable, exactly like
---      `telemetry/command.lua`'s own `show` and `:RA usage`'s own
---      rendering. Not a fresh decision — this module's own `M.lines`
---      just plugs into the existing convention.

local M = {}

local DEFAULT_MAX_DEPTH = 3

---@internal
---@param fn function
---@return integer
local function upvalue_count(fn)
  local ok, info = pcall(debug.getinfo, fn, "u")
  return (ok and info and info.nups) or 0
end

---@internal
---@param fn function
---@return { what: string, short_src: string, linedefined: integer }?
local function source_of(fn)
  local ok, info = pcall(debug.getinfo, fn, "S")
  if not ok or not info then
    return nil
  end
  return { what = info.what, short_src = info.short_src, linedefined = info.linedefined }
end

---@internal
---@param t table
---@return integer
local function count_fields(t)
  local n = 0
  for _ in pairs(t) do
    n = n + 1
  end
  return n
end

---A short, honest literal for a scalar value — string/number/boolean
---only. Never attempted for anything else (userdata, thread, a table,
---already handled separately elsewhere): guessing at a useful
---representation for those is exactly the kind of thing this module's
---own "record it, don't guess it" posture refuses.
---@internal
---@param v any
---@return string?
local function scalar_repr(v)
  local vt = type(v)
  if vt == "string" then
    local s = v
    if #s > 60 then
      s = s:sub(1, 57) .. "..."
    end
    return ("%q"):format(s)
  elseif vt == "number" or vt == "boolean" then
    return tostring(v)
  end
  return nil
end

---Which of `t`'s own direct string keys are *shadowing* — also reachable
---through its metatable's `__index`, when (and only when) `__index` is
---itself a table. `nil` when there is no metatable, no `__index`, or
---`__index` is a function — see the module doc-comment's second design
---question for why a function `__index` is never called to find out.
---@internal
---@param t table
---@return table<string, true>? shadowed
local function shadowed_keys(t)
  local mt = getmetatable(t)
  local index = mt and mt.__index
  if type(index) ~= "table" then
    return nil
  end
  local out = {}
  for k in pairs(t) do
    if type(k) == "string" and index[k] ~= nil then
      out[k] = true
    end
  end
  return out
end

---@internal
---@param mt table?
---@return "table"|"function"|"other"|nil
local function index_kind_of(mt)
  local index = mt and mt.__index
  if index == nil then
    return nil
  end
  if type(index) == "table" then
    return "table"
  elseif type(index) == "function" then
    return "function"
  end
  return "other"
end

---@internal
---@param t table
---@param seen table<table, true>
---@param depth integer
---@param max_depth integer
---@return RA.Inspect.Node node
local function walk(t, seen, depth, max_depth)
  local mt = getmetatable(t)
  local shadows = shadowed_keys(t)

  local keys = {}
  for k in pairs(t) do
    if type(k) == "string" then
      keys[#keys + 1] = k
    end
  end
  table.sort(keys)

  local entries = {}
  for _, k in ipairs(keys) do
    local v = t[k]
    local vt = type(v)
    local shadows_index = (shadows and shadows[k]) or false

    if vt == "function" then
      entries[#entries + 1] = {
        key = k,
        kind = "function",
        nups = upvalue_count(v),
        source = source_of(v),
        shadows_index = shadows_index,
      }
    elseif vt == "table" then
      local child
      if seen[v] then
        child = { key = k, kind = "table", cyclic = true }
      elseif depth >= max_depth then
        child = { key = k, kind = "table", truncated = true, field_count = count_fields(v) }
      else
        seen[v] = true
        child = walk(v, seen, depth + 1, max_depth)
        seen[v] = nil -- only the ancestor chain matters -- a table shared
        -- between two sibling branches (not nested in itself) is not a
        -- cycle, and must still be walked the second time it is reached.
        child.key = k
      end
      child.shadows_index = shadows_index
      entries[#entries + 1] = child
    else
      entries[#entries + 1] = {
        key = k,
        kind = "other",
        value_type = vt,
        value_repr = scalar_repr(v),
        shadows_index = shadows_index,
      }
    end
  end

  return {
    kind = "table",
    entries = entries,
    has_metatable = mt ~= nil,
    index_kind = index_kind_of(mt),
  }
end

---Walk `package.loaded[module_id]` and report its shape.
---@param module_id string
---@param opts { max_depth?: integer }?
---@return RA.Inspect.Report? report `nil` when `module_id` is not loaded, or is
---loaded but is not a table at all (a module whose `require()` return is
---a function or a plain value has nothing for this to walk).
---@return string? err
function M.inspect(module_id, opts)
  if type(module_id) ~= "string" or module_id == "" then
    return nil, "module_id must be a non-empty string"
  end
  local mod = package.loaded[module_id]
  if mod == nil then
    return nil, ("%q is not loaded in this session"):format(module_id)
  end
  if type(mod) ~= "table" then
    return nil, ("%q is loaded, but is a %s, not a table"):format(module_id, type(mod))
  end

  local max_depth = (opts and opts.max_depth) or DEFAULT_MAX_DEPTH
  local report = walk(mod, { [mod] = true }, 1, max_depth)
  report.module_id = module_id
  return report, nil
end

---@internal
---@param node RA.Inspect.Node one `walk` entry
---@param indent string
---@param out string[]
local function render(node, indent, out)
  local shadow_note = node.shadows_index and "  [shadows __index]" or ""

  if node.kind == "function" then
    local src
    if not node.source then
      src = "source unavailable"
    elseif node.source.what == "C" then
      src = "C function"
    else
      src = ("%s:%d"):format(node.source.short_src, node.source.linedefined)
    end
    out[#out + 1] = ("%s%s()  [%d upvalue(s), %s]%s"):format(
      indent,
      node.key,
      node.nups,
      src,
      shadow_note
    )
  elseif node.kind == "table" and node.cyclic then
    out[#out + 1] = ("%s%s  {cycle — already on this branch}%s"):format(
      indent,
      node.key,
      shadow_note
    )
  elseif node.kind == "table" and node.truncated then
    out[#out + 1] = ("%s%s  {%d field(s), depth limit reached}%s"):format(
      indent,
      node.key,
      node.field_count,
      shadow_note
    )
  elseif node.kind == "table" then
    local mt_note = ""
    if node.has_metatable then
      mt_note = node.index_kind and (", __index: " .. node.index_kind) or ", has metatable"
    end
    out[#out + 1] = ("%s%s  {%d field(s)%s}%s"):format(
      indent,
      node.key or "",
      #node.entries,
      mt_note,
      shadow_note
    )
    for _, child in ipairs(node.entries) do
      render(child, indent .. "  ", out)
    end
  else -- "other"
    local repr = node.value_repr and (" = " .. node.value_repr) or ""
    out[#out + 1] = ("%s%s  <%s>%s%s"):format(indent, node.key, node.value_type, repr, shadow_note)
  end
end

---@param report RA.Inspect.Report `M.inspect`'s own return
---@return string[]
function M.lines(report)
  local out = { report.module_id }
  if report.has_metatable then
    out[#out + 1] = ("has metatable, __index: %s"):format(report.index_kind or "none")
  end
  for _, entry in ipairs(report.entries) do
    render(entry, "  ", out)
  end
  return out
end

return M
