---@module 'runtime-analysis.loaded'
--- Enumerate what a module actually has on its table right now —
--- docs/ROADMAP.md §5.3, the half of "diff loaded-vs-declared" this
--- repository owns. documentation.nvim knows every function the source
--- *declares*; this answers what `package.loaded` actually holds in the
--- current process, which the static half structurally cannot: a module
--- never required this session, a field a metatable materializes only on
--- first access, a key nothing in the source names because it was built
--- from a loop.
---
--- **The one honest limit that shapes everything here.** This reads
--- `package.loaded` in *this* Neovim process — not "was `M.foo` ever
--- declared anywhere", but "is it on the table right now, in the session
--- asking". A tree analyzed from a process that never actually loaded it
--- (a headless `:DocMap check` run, a different Neovim entirely) sees
--- nothing and must render that as "not loaded here", never as "declared
--- but dead" — the identical "absence of data is not evidence" rule the
--- telemetry join (ECOSYSTEM.md step 8, in documentation.nvim) already
--- states for its own case. The real use case this answers cleanly is a
--- config author pointing `:DocBrowse` at the very config that is running
--- it — the plugin under analysis and the plugin doing the analysis are
--- the same live session, so `package.loaded` genuinely means something.
---
--- No wrapping, no instrumentation, no cost question the way telemetry's
--- own `debug.getinfo` measurement (§3.1) needed one: `pairs()` over one
--- already-in-memory table, called on demand, never on a hot path.

local M = {}

---Every function-valued key directly on `package.loaded[module_id]` — one
---level, matching how documentation.nvim's own IR keys a node's functions
---(`node.module .. "#" .. fn.name`, no deeper qualification): a nested
---table under a key is a further require-able module in its own right
---(its own IR node, its own separate call to this function), not a
---field of this one.
---@param module_id string A real Lua require() path, e.g. "runtime-analysis.telemetry".
---@return table<string, true>? keys `nil` when nothing is loaded at
---`package.loaded[module_id]` at all — a real table with fewer entries
---(possibly zero) is a different, meaningful answer: loaded, but nothing
---function-shaped survived (an aggregate of pure data, say).
function M.functions(module_id)
  if type(module_id) ~= "string" or module_id == "" then
    return nil
  end
  local mod = package.loaded[module_id]
  if type(mod) ~= "table" then
    return nil
  end
  local out = {}
  for k, v in pairs(mod) do
    if type(k) == "string" and type(v) == "function" then
      out[k] = true
    end
  end
  return out
end

---Whether `module_id` has been `require()`'d at all in this session —
---the cheapest, most literal answer to §5.1's own "is this module even
---loaded" question, and the precondition `M.functions` itself already
---checks; exposed separately because a caller may want to say so plainly
---("not loaded") rather than render an empty function set as if it were
---one.
---@param module_id string
---@return boolean
function M.is_loaded(module_id)
  return type(module_id) == "string" and package.loaded[module_id] ~= nil
end

-- -----------------------------------------------------------------------
-- Persisted snapshots — docs/ROADMAP.md §5.4.
--
-- `loaded.lua`'s own header already states the limit this section cannot
-- lift: "declared but dead" vs. "not loaded here" is a distinction only a
-- live process can draw, because it is reading `package.loaded` in *this*
-- process, right now. A snapshot does not change what can be known — it
-- only lets a *later* process (or a later moment in this one) see what
-- *was* loaded at the time it was taken, the same trade-off telemetry's
-- own named snapshots (§4.5) already make for call counts: a point-in-time
-- capture of a live fact, not a way around the fact being live.
--
-- Storage deliberately parallels `telemetry/store.lua` rather than reusing
-- it: same `lib.nvim.cache.disk` primitive, same sanitize/snapshot_dir/
-- list/evict shape, own `"loaded/"` cache-key prefix so the two never
-- collide on disk — but a loaded snapshot is a different kind of fact (a
-- module→function-keys map, not a call-count aggregate), and reaching
-- into telemetry's own store module for it would couple two unrelated
-- concerns for no real saving over the ~30 lines below.
--
-- **One identifier, not two.** Telemetry genuinely needs a separate
-- namespace from whatever module prefix it wraps — `core/telemetry_self.lua`
-- wraps `main = "documentation"` (the require path) under
-- `namespace = "documentation.nvim"` (`opts.title`), and those differ for
-- this repo itself. A loaded snapshot has no such split to make: it is
-- scoped by `prefix` (the same convention `wrap_loaded(prefix)` already
-- uses) and nothing else, so `prefix` is also the storage key — the
-- alternative (a caller-chosen namespace kept in sync with the prefix by
-- hand) would be one more thing to get out of sync for no benefit, since
-- documentation.nvim's own reading side can derive the identical `prefix`
-- from `opts.source` without needing to be told a second string.
-- -----------------------------------------------------------------------

local disk = require("lib.nvim.cache.disk")

--- Everything but these is replaced with `_` — the same rule and the same
--- reason `telemetry/store.lua#M.sanitize` states: `prefix`/`name` are
--- caller-chosen strings, and allowing separators is how `..` would escape
--- the cache directory.
local SAFE = "[^%w%-%._]"

---@internal
---@param s string
---@return string
local function sanitize(s)
  local out = tostring(s or ""):gsub(SAFE, "_")
  out = out:gsub("^%.+", "")
  if out == "" then
    out = "unnamed"
  end
  return out
end

---@internal
---@param prefix string
---@return string
local function cache_key(prefix)
  return "loaded/" .. sanitize(prefix)
end

---@internal
---@param prefix string
---@param name string
---@return string
local function snapshot_cache_key(prefix, name)
  return cache_key(prefix) .. "/snapshots/" .. sanitize(name)
end

---@internal
---@param prefix string
---@return string
local function snapshot_dir(prefix)
  return vim.fn.stdpath("cache") .. "/lib.nvim/cache/" .. cache_key(prefix) .. "/snapshots"
end

---How many named snapshots a prefix keeps before `M.snapshot` starts
---evicting the oldest — same default and the same reasoning
---`telemetry.SNAPSHOT_RETENTION` already has (docs/ROADMAP.md §4.5): kept
---bounded rather than left to grow forever, since nothing here ever prunes
---on its own.
M.SNAPSHOT_RETENTION = 20

---Capture every currently-loaded module under `prefix` (itself, or
---anything beginning `prefix .. "."` — the identical scoping
---`runtime-analysis.telemetry`'s own `wrap_loaded(prefix)` already uses,
---so the same prefix that instruments a plugin also snapshots it) as a
---named, persisted snapshot: `{ [module_id] = M.functions(module_id) }`
---for every match.
---
---**Always explicit**, the same posture `telemetry.snapshot` already
---takes and for the identical reason: nothing here ever snapshots on its
---own (no autocmd, no interval), so an unexpected capture cannot silently
---start evicting a prefix's older, possibly still-wanted ones. The only
---call site is `:RA loaded snapshot <prefix> [name]`.
---@param prefix string Module-id prefix to scope the walk to, e.g. `"documentation"` — also the storage key; see this section's own header for why there is no separate namespace argument.
---@param name? string Default: a timestamp (`os.date("%Y-%m-%dT%H-%M-%S")`), the same default `telemetry.snapshot` uses.
---@return string|nil saved_name `nil` when `prefix` is invalid, or nothing under it is loaded at all.
function M.snapshot(prefix, name)
  if type(prefix) ~= "string" or prefix == "" then
    return nil
  end

  local modules = {}
  local any = false
  for key in pairs(package.loaded) do
    if type(key) == "string" and (key == prefix or key:sub(1, #prefix + 1) == prefix .. ".") then
      local fns = M.functions(key)
      if fns then
        modules[key] = fns
        any = true
      end
    end
  end
  if not any then
    return nil
  end

  local snapshot_name = sanitize(name or os.date("%Y-%m-%dT%H-%M-%S"))
  local data = { version = 1, prefix = prefix, captured_at = os.time(), modules = modules }
  local ok = disk.save(snapshot_cache_key(prefix, snapshot_name), data)
  if not ok then
    return nil
  end

  M.evict_old_snapshots(prefix)
  return snapshot_name
end

---Every snapshot saved for `prefix`, newest first — the same shape
---`telemetry.list_snapshots` already returns, for a picker UI
---(`:RA loaded snapshots <prefix>`, or documentation.nvim's own Loaded
---panel) to build a list from.
---@param prefix string
---@return { name: string, saved_at: integer }[]
function M.list_snapshots(prefix)
  if type(prefix) ~= "string" or prefix == "" then
    return {}
  end
  local dir = snapshot_dir(prefix)
  local uv = vim.uv or vim.loop

  local handle = uv.fs_scandir(dir)
  if not handle then
    return {}
  end

  local out = {}
  while true do
    local name, kind = uv.fs_scandir_next(handle)
    if not name then
      break
    end
    if kind == "file" and name:match("%.json$") then
      local snapshot_name = name:gsub("%.json$", "")
      local stat = uv.fs_stat(dir .. "/" .. name)
      out[#out + 1] = { name = snapshot_name, saved_at = stat and stat.mtime.sec or 0 }
    end
  end

  table.sort(out, function(a, b)
    return a.saved_at > b.saved_at
  end)
  return out
end

---Read one named snapshot back.
---@param prefix string
---@param name string
---@return { version: integer, prefix: string, captured_at: integer, modules: table<string, table<string, true>> }|nil `nil` when `name` was never saved for `prefix` (or was and has since been evicted).
function M.load_snapshot(prefix, name)
  if type(prefix) ~= "string" or prefix == "" or type(name) ~= "string" or name == "" then
    return nil
  end
  local ok, raw = pcall(disk.load, snapshot_cache_key(prefix, name))
  if not ok or raw == nil then
    return nil
  end
  return raw
end

---@internal
---@param prefix string
---@param name string
---@return boolean ok
local function delete_snapshot(prefix, name)
  local ok, cleared = pcall(disk.clear, snapshot_cache_key(prefix, name))
  return ok and cleared ~= false
end

---Evict the oldest snapshots beyond `M.SNAPSHOT_RETENTION` — called after
---every `M.snapshot`, the identical policy `telemetry.evict_old_snapshots`
---already has, including the same `keep <= 0` → "do not evict" guard
---against an unset/zero value wiping a prefix's whole history.
---@param prefix string
---@return integer evicted
function M.evict_old_snapshots(prefix)
  local keep = M.SNAPSHOT_RETENTION
  if not keep or keep <= 0 then
    return 0
  end
  local all = M.list_snapshots(prefix)
  local evicted = 0
  for i = keep + 1, #all do
    if delete_snapshot(prefix, all[i].name) then
      evicted = evicted + 1
    end
  end
  return evicted
end

return M
