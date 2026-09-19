---@module 'runtime-analysis.telemetry.toggle'
--- Persistent per-namespace enable/disable, independent of any instance's own
--- collected data.
---
--- WHY THIS IS SEPARATE FROM start()/stop()
--- `inst.stop()` only affects the current process; the next `require(...).new()`
--- + `t.start()` in tomorrow's session installs the wrapper again exactly as
--- before. That is correct for "pause it for a minute" but wrong for "I looked
--- at markdown.nvim's numbers, I'm done, stop wrapping it" — the caller that
--- calls `t.start()` (a config, wired once at startup) has no idea a user
--- decided that mid-session, and re-editing that caller's source every time is
--- exactly the friction a `:RATelemetry disable <ns>` command should remove.
---
--- So the "disabled" flag lives on disk (same `cache.disk` backend the counts
--- themselves use, but its own file — a namespace's toggle state is not part
--- of that namespace's data, and clearing counts with `:RATelemetry reset`
--- must not also silently re-enable it). `inst.start()` checks it and is a
--- no-op while disabled; the CALLER's `t.start()` call does not need to
--- change at all, which is the point — the toggle takes effect without
--- touching whoever wired the instance up in the first place.
---
--- This is deliberately GLOBAL, not per-namespace-dir: unlike an instance's
--- own counts (which follow that instance's `opts.dir`), "should this even
--- run" is a cross-session user decision that has to be readable before any
--- particular instance's options are known — a namespace can be disabled
--- before it has ever loaded. The optional `opts.dir` on every function below
--- exists only so tests do not read/write the real `stdpath("cache")`; real
--- callers never pass it.

local disk = require("lib.nvim.cache.disk")
local notify = require("lib.nvim.notify").create("[runtime-analysis.telemetry]")

local M = {}

local CACHE_KEY = "telemetry/_control"
-- `disk`'s own hardcoded default is `stdpath("cache")/lib.nvim/cache` — wrong
-- root now that telemetry lives here, so real callers (opts == nil below) get
-- this default threaded through explicitly instead.
local DEFAULT_DIR = vim.fn.stdpath("cache") .. "/runtime-analysis.nvim/cache"

---@type table<string, boolean>|nil
local disabled = nil

-- Warned at most once per session: `load()` runs on every `is_disabled()`
-- call while the module-level cache is cold, and a decode failure does not
-- change between those calls, so repeating the warning would just be noise.
local warned_corrupt = false

---@internal
---@param err string
local function warn_corrupt_once(err)
  if warned_corrupt then
    return
  end
  warned_corrupt = true
  notify.warn(
    ("the telemetry enable/disable state could not be read and is being rebuilt; the original file was kept as a backup (%s)"):format(
      err
    )
  )
end

---ERR-11: `M.disable`/`M.enable` are a load-modify-save cycle over this
---exact table -- they call this, flip one namespace's flag, and hand the
---WHOLE table to `persist()`, which rewrites the WHOLE control file. A
---decode failure collapsing straight to `{}` here means the very next
---`:RATelemetry disable <ns>` (for any namespace) silently drops every
---*other* namespace's disabled flag, with nothing said about it. The
---original bytes are already safe -- `disk.load` backs them up to
---`<path>.corrupt` once before ever returning an error -- so this only
---makes the distinction visible instead of silent.
---@internal
---@param opts? Lib.Cache.Opts
---@return table<string, boolean>
local function load(opts)
  -- An explicit `dir` (tests only) always bypasses the module-level cache —
  -- otherwise the first test to run would pin `disabled` to its own tmp dir's
  -- contents for every test after it in the same process.
  if opts and opts.dir then
    local ok, data, err = pcall(disk.load, CACHE_KEY, opts)
    if ok and type(data) == "table" and type(data.disabled) == "table" then
      return data.disabled
    end
    if ok and err then
      warn_corrupt_once(err)
    end
    return {}
  end

  if disabled then
    return disabled
  end
  local ok, data, err = pcall(disk.load, CACHE_KEY, { dir = DEFAULT_DIR })
  if ok and type(data) == "table" and type(data.disabled) == "table" then
    disabled = data.disabled
  else
    disabled = {}
    if ok and err then
      warn_corrupt_once(err)
    end
  end
  return disabled
end

---@internal
---@param d table<string, boolean>
---@param opts? Lib.Cache.Opts
local function persist(d, opts)
  pcall(disk.save, CACHE_KEY, { disabled = d }, opts or { dir = DEFAULT_DIR })
end

---@param namespace string
---@param opts? Lib.Cache.Opts
---@return boolean
function M.is_disabled(namespace, opts)
  return load(opts)[namespace] == true
end

---@param namespace string
---@param opts? Lib.Cache.Opts
function M.disable(namespace, opts)
  local d = load(opts)
  d[namespace] = true
  persist(d, opts)
end

---@param namespace string
---@param opts? Lib.Cache.Opts
function M.enable(namespace, opts)
  local d = load(opts)
  if d[namespace] then
    d[namespace] = nil
    persist(d, opts)
  end
end

---Every namespace currently marked disabled, sorted.
---@param opts? Lib.Cache.Opts
---@return string[]
function M.disabled_list(opts)
  local out = {}
  for ns in pairs(load(opts)) do
    out[#out + 1] = ns
  end
  table.sort(out)
  return out
end

---Test-only: drop the module-level cache and the once-per-session corrupt
---warning back to their startup state, the same reason
---`runtime-analysis.env._reset_for_test()` exists — so a spec exercising
---`load()`'s corrupt-file path does not leave `warned_corrupt` pinned
---`true` for whatever spec happens to run after it in the same process.
function M._reset_for_test()
  disabled = nil
  warned_corrupt = false
end

return M
