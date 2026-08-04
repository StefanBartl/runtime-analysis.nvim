---@module 'runtime-analysis.telemetry.registry'
--- Module-level bookkeeping for every installed wrapper, shared by all
--- telemetry instances.
---
--- WHY THIS IS SHARED RATHER THAN PER-INSTANCE
--- If two instances (say lib.nvim's and lsp.nvim's) both wrapped the same
--- function, the naive design nests wrappers: both count the call, and the
--- inner one restoring first leaves the outer holding a wrapper it will later
--- reinstall as "the original" — instrumentation stuck on with nothing to
--- notice it. So a function is wrapped at most ONCE, here, and instances
--- subscribe to it. Restore happens when the last subscriber detaches, and
--- double counting is structurally impossible rather than merely unlikely.
---
--- Everything in this file is on the hot path when telemetry is running. It
--- does exactly two things per call in the cheapest mode: index a table and
--- add one integer. No clock reads, no `vim.*`, nothing that would make a
--- wrapper unsafe in a fast event context.

local uv = vim.uv or vim.loop

local fingerprint = require("runtime-analysis.telemetry.fingerprint")

local M = {}

local unpack_ = table.unpack or unpack

--- `{ original(...) }` loses everything after a nil, and a wrapped function
--- returning `1, nil, 3` must still return `1, nil, 3`. Capture the arity.
local pack = table.pack or function(...)
  return { n = select("#", ...), ... }
end

--- container table -> field name -> site
---@type table<table, table<string, table>>
local sites = setmetatable({}, { __mode = "k" })

-- ---------------------------------------------------------------------------
-- Flags
-- ---------------------------------------------------------------------------

---Recompute the per-site "does anyone want this?" flags. Called whenever the
---subscriber set or an instance's mode changes — never per call.
---@internal
---@param site table
local function refresh(site)
  local args, time, errors, outermost, callers = false, false, false, false, false
  local sample_rate, sample_blocked = nil, false
  local subs = site.subs
  for i = 1, #subs do
    local s = subs[i]
    args = args or s.args
    time = time or s.time
    errors = errors or s.errors
    outermost = outermost or s.outermost_only
    callers = callers or s.callers

    -- docs/ROADMAP.md §3.2: sampling is the MINIMUM (most eager) rate any
    -- subscriber that actually wants expensive work asks for -- so the
    -- pickiest subscriber's own sample size is never starved by a laxer
    -- one. A subscriber that wants expensive work with NO sample opt of
    -- its own needs every call in full, which makes sampling unsafe for
    -- this site at all: `sample_blocked` overrides any rate collected
    -- from other subscribers rather than the two silently coexisting.
    if s.args or s.time or s.errors or s.outermost_only or s.callers then
      if s.sample then
        if not sample_rate or s.sample < sample_rate then
          sample_rate = s.sample
        end
      else
        sample_blocked = true
      end
    end
  end
  site.needs_args = args
  site.needs_time = time
  site.needs_errors = errors
  site.needs_depth = outermost
  site.needs_callers = callers
  site.sample_rate = (not sample_blocked) and sample_rate or nil
end

---@param site table
---@param fp string|nil
---@param dur number|nil
---@param errored boolean
---@param err_fp string|nil
---@param caller_key string|nil docs/ROADMAP.md §3.1 -- `"short_src:currentline"` of the immediate caller, or nil when nobody wants it or `debug.getinfo` returned nothing (a C caller, e.g. `vim.schedule`'s own dispatch)
---@internal
local function dispatch(site, fp, dur, errored, err_fp, caller_key)
  local subs = site.subs
  for i = 1, #subs do
    local s = subs[i]
    s.inst._record(
      s.key,
      s.args and fp or nil,
      s.time and dur or nil,
      errored,
      s.errors and err_fp or nil,
      s.callers and caller_key or nil
    )
  end
end

-- ---------------------------------------------------------------------------
-- The wrapper
-- ---------------------------------------------------------------------------

---@internal
---@param site table
---@return function
local function make_wrapper(site)
  return function(...)
    local original = site.original

    -- Cheapest path, and the one that must stay cheap: counting only.
    -- Tail-called, so the wrapper adds no frame to the callee's stack and
    -- multiple return values pass through untouched.
    if
      not (
        site.needs_args
        or site.needs_time
        or site.needs_errors
        or site.needs_depth
        or site.needs_callers
      )
    then
      dispatch(site, nil, nil, false)
      return original(...)
    end

    -- Sampling (docs/ROADMAP.md §3.2): decide once per call whether THIS
    -- call pays for the expensive path below at all, or takes the same
    -- cheap counting-only path the branch above already uses. `calls`
    -- stays exact regardless — it was already free — only args/timing/
    -- errors/depth/callers become an estimate from the sampled subset,
    -- which is exactly what makes them affordable on a hot surface in the
    -- first place (README.md's own "Sampling" section states the honest
    -- limit this creates).
    if site.sample_rate then
      site.sample_tick = (site.sample_tick or 0) + 1
      if site.sample_tick % site.sample_rate ~= 0 then
        dispatch(site, nil, nil, false)
        return original(...)
      end
    end

    local fp
    if site.needs_args then
      fp = fingerprint.of(select("#", ...), ...)
    end

    -- docs/ROADMAP.md §3.1: one frame of `debug.getinfo`, at the cheapest
    -- field set that still names a real call site — `"Sl"` (source +
    -- current line), not `"Sln"` (+ name resolution), which measured
    -- ~1.5x more expensive for a caller *name* this already has a cheaper,
    -- unambiguous substitute for: a source:line pair identifies the exact
    -- call site, which is the same join key `documentation.nvim`'s own
    -- static `calls` extraction already uses (a call edge's `line`, not a
    -- resolved caller name). Level 2 from inside this wrapper is the
    -- wrapper's own caller — the immediate caller of the wrapped function,
    -- exactly what "by whom" asks. `nil` when the caller has no Lua frame
    -- to report (a C caller, e.g. `vim.schedule`'s own dispatch) rather
    -- than a placeholder string a report would have to special-case.
    local caller_key
    if site.needs_callers then
      local info = debug.getinfo(2, "Sl")
      if info and info.short_src then
        caller_key = info.short_src .. ":" .. (info.currentline or 0)
      end
    end

    -- Depth tracking and error counting both need the call to return through
    -- us even when it raises, which means pcall — hence both are opt-in.
    if site.needs_depth or site.needs_errors then
      site.depth = site.depth + 1
      local outermost = site.depth == 1

      local t0 = site.needs_time and uv.hrtime() or nil
      local res = pack(pcall(original, ...))
      local dur = t0 and (uv.hrtime() - t0) / 1e6 or nil

      site.depth = site.depth - 1

      if outermost or not site.needs_depth then
        -- Fingerprinted the same way an argument would be (§2.5's roadmap
        -- entry: "reuses the existing argument-fingerprint machinery,
        -- pointed at errors instead of arguments") -- only computed on the
        -- branch that already pays for `pcall` and only when a raised
        -- error actually happened, so the success-path cost this module's
        -- whole premise rests on is untouched either way.
        local err_fp = (not res[1] and site.needs_errors) and fingerprint.value(res[2]) or nil
        dispatch(site, fp, dur, not res[1], err_fp, caller_key)
      end

      if not res[1] then
        error(res[2], 0)
      end
      return unpack_(res, 2, res.n)
    end

    if site.needs_time then
      local t0 = uv.hrtime()
      local res = pack(original(...))
      dispatch(site, fp, (uv.hrtime() - t0) / 1e6, false, nil, caller_key)
      return unpack_(res, 1, res.n)
    end

    dispatch(site, fp, nil, false, nil, caller_key)
    return original(...)
  end
end

-- ---------------------------------------------------------------------------
-- Attach / detach
-- ---------------------------------------------------------------------------

---Subscribe `inst` to calls of `container[field]`, installing the wrapper if
---this is the first subscriber.
---@param container table
---@param field string
---@param key string            # the label reported for this instance
---@param inst table            # must expose `_record(key, fp, dur_ms, errored, err_fp)`
---@param wants table           # { args, time, errors, outermost_only, callers, sample }
---@return boolean ok
function M.attach(container, field, key, inst, wants)
  local original = rawget(container, field)
  if type(original) ~= "function" then
    return false
  end

  local by_field = sites[container]
  if not by_field then
    by_field = {}
    sites[container] = by_field
  end

  local site = by_field[field]
  if not site then
    site = { container = container, field = field, original = original, subs = {}, depth = 0 }
    site.wrapper = make_wrapper(site)
    by_field[field] = site
    container[field] = site.wrapper
  elseif container[field] ~= site.wrapper then
    -- Someone replaced the field after we wrapped it (hot reload, a plugin
    -- monkey-patching the same function). Their value is the one callers
    -- should reach, so adopt it as the new original instead of silently
    -- shadowing it — and re-install so we still see the calls.
    site.original = container[field]
    container[field] = site.wrapper
  end

  for i = 1, #site.subs do
    if site.subs[i].inst == inst then
      local s = site.subs[i]
      s.key, s.args, s.time = key, wants.args, wants.time
      s.errors, s.outermost_only = wants.errors, wants.outermost_only
      s.callers = wants.callers
      s.sample = wants.sample
      refresh(site)
      return true
    end
  end

  site.subs[#site.subs + 1] = {
    inst = inst,
    key = key,
    args = wants.args or false,
    time = wants.time or false,
    errors = wants.errors or false,
    outermost_only = wants.outermost_only or false,
    callers = wants.callers or false,
    sample = wants.sample,
  }
  refresh(site)
  return true
end

---Unsubscribe `inst`; restores the original once nobody is left.
---@param container table
---@param field string
---@param inst table
function M.detach(container, field, inst)
  local by_field = sites[container]
  local site = by_field and by_field[field]
  if not site then
    return
  end

  for i = #site.subs, 1, -1 do
    if site.subs[i].inst == inst then
      table.remove(site.subs, i)
    end
  end

  if #site.subs > 0 then
    refresh(site)
    return
  end

  -- Last one out restores. Only if the field is still *our* wrapper — if
  -- something replaced it since, overwriting would undo their change.
  if container[field] == site.wrapper then
    container[field] = site.original
  end
  by_field[field] = nil
  if next(by_field) == nil then
    sites[container] = nil
  end
end

---True while `container[field]` is an installed wrapper.
---@param container table
---@param field string
---@return boolean
function M.is_wrapped(container, field)
  local by_field = sites[container]
  local site = by_field and by_field[field]
  return site ~= nil and container[field] == site.wrapper
end

---Which telemetry instance(s), if any, currently wrap `container[field]` —
---docs/ROADMAP.md §5.2. Precise, unlike anything about a *non*-telemetry
---wrapper this plugin might sit next to: this registry is the one shared
---wrap layer every telemetry instance goes through (see the module
---doc-comment on why), so it genuinely knows every subscriber by name.
---@param container table
---@param field string
---@return { wrapped: boolean, namespaces: string[] }
function M.info(container, field)
  local by_field = sites[container]
  local site = by_field and by_field[field]
  if not site or container[field] ~= site.wrapper then
    return { wrapped = false, namespaces = {} }
  end
  local namespaces = {}
  for i = 1, #site.subs do
    namespaces[#namespaces + 1] = site.subs[i].inst.namespace
  end
  table.sort(namespaces)
  return { wrapped = true, namespaces = namespaces }
end

return M
