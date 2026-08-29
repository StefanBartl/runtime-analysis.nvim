---@module 'runtime-analysis.telemetry.store'
--- Persistence for telemetry counters, on top of `lib.nvim.cache.disk`.
---
--- Two things this file exists to get right:
---
--- 1. **Merge-on-write, not last-write-wins.** Counts are per-process, and two
---    Neovim instances sharing a namespace would otherwise overwrite each
---    other's totals. Every flush re-reads what is on disk and adds only the
---    delta collected since the previous flush.
--- 2. **Namespace sanitization.** `cache.disk` builds its path as
---    `dir .. "/" .. namespace .. ".json"` with no escaping, and a namespace is
---    a plugin-chosen string. `"../../evil"` would write outside the cache
---    directory. Sanitizing here is cheap; changing `cache.disk` would be a
---    wider change affecting every existing caller.

local disk = require("lib.nvim.cache.disk")

local M = {}

M.VERSION = 1

--- Everything but these is replaced with `_`. Slashes included: `cache.disk`
--- supports nested namespaces, but a telemetry namespace is a plugin name, and
--- allowing separators is exactly how `..` escapes the cache directory.
local SAFE = "[^%w%-%._]"

---@param namespace string
---@return string
function M.sanitize(namespace)
  local s = tostring(namespace or ""):gsub(SAFE, "_")
  -- A name of only dots still resolves relative to the cache dir.
  s = s:gsub("^%.+", "")
  if s == "" then
    s = "unnamed"
  end
  return s
end

---@param namespace string
---@return string
function M.cache_key(namespace)
  return "telemetry/" .. M.sanitize(namespace)
end

---@return string  # "YYYY-MM-DD" in local time
function M.today()
  return os.date("%Y-%m-%d") --[[@as string]]
end

---An empty, well-formed data table.
---@return RA.Telemetry.Data
function M.empty()
  return {
    version = M.VERSION,
    started_at = os.time(),
    sessions = 0,
    functions = {},
    days = {},
    reminded = {},
    modules = {},
    info = {},
  }
end

---Normalize whatever came back from disk into the current shape.
---@internal
---@param raw any
---@return RA.Telemetry.Data
local function normalize(raw)
  if type(raw) ~= "table" or raw.version ~= M.VERSION then
    return M.empty()
  end
  raw.functions = type(raw.functions) == "table" and raw.functions or {}
  raw.days = type(raw.days) == "table" and raw.days or {}
  raw.reminded = type(raw.reminded) == "table" and raw.reminded or {}
  raw.sessions = tonumber(raw.sessions) or 0
  raw.started_at = tonumber(raw.started_at) or os.time()
  -- Added after version 1 shipped; older cache files simply lack it. Purely
  -- additive, so this does not warrant a version bump — a missing map and an
  -- empty one mean the same thing to every reader.
  raw.modules = type(raw.modules) == "table" and raw.modules or {}
  raw.info = type(raw.info) == "table" and raw.info or {}
  return raw
end

---@param namespace string
---@param opts? Lib.Cache.Opts
---@return RA.Telemetry.Data
function M.load(namespace, opts)
  local ok, raw = pcall(disk.load, M.cache_key(namespace), opts)
  return normalize(ok and raw or nil)
end

---Like `load`, but distinguishes "nothing was ever persisted" from "persisted
---and empty" — returns `nil` rather than a well-formed empty table when no
---cache entry exists for `namespace`.
---
---`load()` collapses that distinction on purpose: a live instance's `base`
---always wants *something* to merge into, and "never flushed before" and
---"flushed, zero counts" are the same starting point for it. A caller reading
---a namespace it does not own — no live instance, possibly never enabled
---here at all — needs to tell those apart, or "no data" renders as a
---graveyard instead of "no data". See `telemetry.load()`.
---@param namespace string
---@param opts? Lib.Cache.Opts
---@return RA.Telemetry.Data|nil
function M.load_readonly(namespace, opts)
  local ok, raw = pcall(disk.load, M.cache_key(namespace), opts)
  if not ok or raw == nil then
    return nil
  end
  return normalize(raw)
end

---Where this namespace's counters actually live.
---
---Built here rather than read from `cache.disk`, which keeps its path
---construction private. That is a duplicated rule, so it is asserted rather
---than trusted: `telemetry_flush_spec.lua` saves through `M.save` and checks
---that the file this returns is the one that appeared.
---
---For telling a reader where their data went. Nothing in this module reads
---it — a caller that wants the *data* calls `M.load`.
---@param namespace string
---@param opts? Lib.Cache.Opts
---@return string
function M.data_path(namespace, opts)
  local dir = (opts and opts.dir) or (vim.fn.stdpath("cache") .. "/lib.nvim/cache")
  return dir .. "/" .. M.cache_key(namespace) .. ".json"
end

---@param namespace string
---@param data RA.Telemetry.Data
---@param opts? Lib.Cache.Opts
---@return boolean ok
function M.save(namespace, data, opts)
  local ok, saved = pcall(disk.save, M.cache_key(namespace), data, opts)
  return ok and saved == true
end

---@param namespace string
---@param opts? Lib.Cache.Opts
---@return boolean ok
function M.clear(namespace, opts)
  local ok, cleared = pcall(disk.clear, M.cache_key(namespace), opts)
  return ok and cleared ~= false
end

---Every namespace with a persisted aggregate — live right now or not, this
---process or a different one. `telemetry.export_all()`'s one building block:
---"every namespace on disk" cannot come from `instances` (module-level, this
---process's live ones only), only from the directory itself.
---
---Reads the directory directly, same reasoning `M.list_snapshots` already
---gives for doing that over a side-index. `_control.json` (the persistent
---disable list, not a namespace's own data) is the one file this
---deliberately excludes; a `snapshots/` subdirectory under a namespace file
---is a directory, not a `.json` file, so it is already excluded by the
---extension check.
---@param opts? Lib.Cache.Opts
---@return string[] namespaces  # sorted
function M.namespaces(opts)
  local root = (opts and opts.dir) or (vim.fn.stdpath("cache") .. "/lib.nvim/cache")
  local dir = root .. "/telemetry"
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
    if kind == "file" and name:match("%.json$") and name ~= "_control.json" then
      out[#out + 1] = name:gsub("%.json$", "")
    end
  end

  table.sort(out)
  return out
end

-- ---------------------------------------------------------------------------
-- Named/dated snapshots.
--
-- `M.load`/`M.save` above are one continuously-overwritten aggregate per
-- namespace: exactly what a live instance wants to merge into, but no way to
-- ask "what did this look like last Tuesday" once today's counts have merged
-- in. A snapshot is a second, independent capture under its own name,
-- written once and never merged into again — nested under the namespace's
-- own `snapshots/` subdirectory (`cache.disk` supports slash-separated
-- namespaces already, the same nesting `M.sanitize`'s own header notes),
-- so listing means scanning one directory rather than filtering a flat
-- namespace list `cache.disk` has no API for in the first place.
-- ---------------------------------------------------------------------------

---Everything but these is replaced with `_`, same rule as `M.sanitize` for
---the same reason — a snapshot name is caller-chosen (a plugin author's
---`:RATelemetry snapshot <name>` argument), and allowing separators would
---let one escape `snapshots/` the same way an unsanitized namespace would
---escape the cache root.
---@param name string
---@return string
function M.sanitize_snapshot_name(name)
  local s = tostring(name or ""):gsub(SAFE, "_")
  s = s:gsub("^%.+", "")
  if s == "" then
    s = "unnamed"
  end
  return s
end

---@param namespace string
---@param name string Not yet sanitized.
---@return string
function M.snapshot_cache_key(namespace, name)
  return M.cache_key(namespace) .. "/snapshots/" .. M.sanitize_snapshot_name(name)
end

---The directory snapshots for `namespace` live under — resolved the same
---way `cache.disk`'s own (private) `cache_dir()` would, duplicated rather
---than exposed from there since this is the only caller that ever needs a
---raw directory rather than a `namespace` key `disk.load`/`disk.save`
---already know how to turn into one.
---@param namespace string
---@param opts? Lib.Cache.Opts
---@return string
function M.snapshot_dir(namespace, opts)
  local root = (opts and opts.dir) or (vim.fn.stdpath("cache") .. "/lib.nvim/cache")
  return root .. "/" .. M.cache_key(namespace) .. "/snapshots"
end

---Save `data` as a new snapshot. Overwrites silently if `name` (after
---sanitizing) already exists — the same "last write under this name wins"
---posture `M.save` itself takes for the live aggregate, and a caller who
---wants uniqueness can check `M.list_snapshots` first.
---@param namespace string
---@param name string
---@param data RA.Telemetry.Data
---@param opts? Lib.Cache.Opts
---@return boolean ok
function M.save_snapshot(namespace, name, data, opts)
  local ok, saved = pcall(disk.save, M.snapshot_cache_key(namespace, name), data, opts)
  return ok and saved == true
end

---@param namespace string
---@param name string
---@param opts? Lib.Cache.Opts
---@return RA.Telemetry.Data|nil
function M.load_snapshot(namespace, name, opts)
  local ok, raw = pcall(disk.load, M.snapshot_cache_key(namespace, name), opts)
  if not ok or raw == nil then
    return nil
  end
  return normalize(raw)
end

---@param namespace string
---@param name string
---@param opts? Lib.Cache.Opts
---@return boolean ok
function M.delete_snapshot(namespace, name, opts)
  local ok, cleared = pcall(disk.clear, M.snapshot_cache_key(namespace, name), opts)
  return ok and cleared ~= false
end

---Every snapshot saved for `namespace`, newest first.
---
---Reads the directory directly (`vim.uv.fs_scandir`, not `disk`'s own API —
---it has none for listing, only single-key load/save/clear) rather than
---keeping a side-index of names: a side-index is one more thing that could
---drift from what is actually on disk, and a directory listing cannot.
---@param namespace string
---@param opts? Lib.Cache.Opts
---@return RA.Telemetry.SnapshotInfo[]
function M.list_snapshots(namespace, opts)
  local dir = M.snapshot_dir(namespace, opts)
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

---Evict the oldest snapshots beyond `keep` — the retention policy for
---`M.list_snapshots`' own growth, called after every `M.save_snapshot` so a
---namespace snapshotted often never accumulates an unbounded set. `keep <=
---0` is treated as "do not evict" rather than "delete everything": a caller
---passing an unset/zero config value by accident must not wipe every
---snapshot silently.
---@param namespace string
---@param keep integer
---@param opts? Lib.Cache.Opts
---@return integer evicted
function M.evict_old_snapshots(namespace, keep, opts)
  if not keep or keep <= 0 then
    return 0
  end
  local all = M.list_snapshots(namespace, opts)
  local evicted = 0
  for i = keep + 1, #all do
    if M.delete_snapshot(namespace, all[i].name, opts) then
      evicted = evicted + 1
    end
  end
  return evicted
end

-- ---------------------------------------------------------------------------
-- Merging
-- ---------------------------------------------------------------------------

---Merges one bounded-cardinality fingerprint bucket into another — shared
---by argument profiling (`functions[key].args`) and error fingerprinting
---(`functions[key].error_fp`), the identical shape
---for both, hence one merge function rather than two copies of it.
---@internal
---@param dst RA.Telemetry.ArgStats
---@param src RA.Telemetry.ArgStats
---@param max_values integer
local function merge_fingerprints(dst, src, max_values)
  dst.values = dst.values or {}
  dst.other = dst.other or 0
  dst.distinct = dst.distinct or 0
  dst.n = dst.n or M.count_keys(dst.values)

  local src_values = src.values or {}

  for fp, n in pairs(src_values) do
    if dst.values[fp] then
      dst.values[fp] = dst.values[fp] + n
    else
      -- Bounded cardinality. Without this the stored size is a function of
      -- user data — a function called with 10 000 distinct paths would cost
      -- 10 000 entries, and telemetry becomes the performance problem it was
      -- written to find.
      dst.distinct = dst.distinct + 1
      if dst.n < max_values then
        dst.values[fp] = n
        dst.n = dst.n + 1
      else
        dst.other = dst.other + n
      end
    end
  end

  -- Fingerprints `src` already evicted into its own `other` bucket are gone as
  -- values but still happened, so their contribution to `distinct` has to be
  -- carried over explicitly. Overlap with `dst` is unknowable once a
  -- fingerprint is dropped — this over-counts rather than silently
  -- under-reporting how varied the arguments were.
  dst.distinct = dst.distinct + math.max(0, (src.distinct or 0) - M.count_keys(src_values))
  dst.other = dst.other + (src.other or 0)
end

---@param t table
---@return integer
function M.count_keys(t)
  local n = 0
  for _ in pairs(t) do
    n = n + 1
  end
  return n
end

---@internal
---@param dst RA.Telemetry.Timing
---@param src RA.Telemetry.Timing
local function merge_timing(dst, src)
  dst.n = (dst.n or 0) + (src.n or 0)
  dst.total_ms = (dst.total_ms or 0) + (src.total_ms or 0)
  dst.min_ms = math.min(dst.min_ms or math.huge, src.min_ms or math.huge)
  dst.max_ms = math.max(dst.max_ms or 0, src.max_ms or 0)
end

---Add `delta` into `base`, in place. Both are `RA.Telemetry.Data`-shaped;
---`delta` typically holds only what one process collected since its last flush.
---@param base RA.Telemetry.Data
---@param delta RA.Telemetry.Data
---@param max_values integer
---@return RA.Telemetry.Data base
function M.merge(base, delta, max_values)
  for key, src in pairs(delta.functions or {}) do
    local dst = base.functions[key]
    if not dst then
      dst = { calls = 0 }
      base.functions[key] = dst
    end
    dst.calls = (dst.calls or 0) + (src.calls or 0)
    if src.errors then
      dst.errors = (dst.errors or 0) + src.errors
    end
    if src.timing then
      dst.timing = dst.timing or {}
      merge_timing(dst.timing, src.timing)
    end
    if src.args then
      dst.args = dst.args or {}
      merge_fingerprints(dst.args, src.args, max_values)
    end
    if src.error_fp then
      dst.error_fp = dst.error_fp or {}
      merge_fingerprints(dst.error_fp, src.error_fp, max_values)
    end
    if src.callers then
      dst.callers = dst.callers or {}
      merge_fingerprints(dst.callers, src.callers, max_values)
    end
  end

  for day, keys in pairs(delta.days or {}) do
    local dst_day = base.days[day]
    if not dst_day then
      dst_day = {}
      base.days[day] = dst_day
    end
    for key, n in pairs(keys) do
      dst_day[key] = (dst_day[key] or 0) + n
    end
  end

  base.sessions = (base.sessions or 0) + (delta.sessions or 0)
  if delta.started_at and delta.started_at < (base.started_at or math.huge) then
    base.started_at = delta.started_at
  end
  for k, v in pairs(delta.reminded or {}) do
    base.reminded[k] = v
  end

  -- Structural, not a count: which key resolves to which real Lua module
  -- path. Stable across sessions by construction (derived from
  -- `package.loaded`), so last-write-wins is equivalent to first-write-wins
  -- here -- there is no meaningful "older" value to preserve.
  base.modules = base.modules or {}
  for key, module_id in pairs(delta.modules or {}) do
    base.modules[key] = module_id
  end

  -- Unlike `modules`, genuinely last-write-wins, not merely equivalent to
  -- it: a branch/version can change between sessions (an upgrade, a
  -- `git checkout`), and the newer session's `info` describes the state
  -- that produced the calls just merged in, not a blend of two states that
  -- were never simultaneously true. Replaced wholesale rather than
  -- key-by-key so a caller who stops setting a field (switches to a
  -- narrower `info` table) does not leave a stale one behind forever.
  if delta.info and next(delta.info) ~= nil then
    base.info = delta.info
  else
    base.info = base.info or {}
  end

  return base
end

---Drop day buckets older than `days`. Bounded growth is the whole reason for
---day keys; without a prune step they are just a slower leak.
---@param data RA.Telemetry.Data
---@param days integer
---@return integer dropped
function M.prune(data, days)
  if not days or days <= 0 then
    return 0
  end
  local cutoff = os.date("%Y-%m-%d", os.time() - days * 86400)
  local dropped = 0
  for day in pairs(data.days or {}) do
    if day < cutoff then
      data.days[day] = nil
      dropped = dropped + 1
    end
  end
  return dropped
end

---Sum the day buckets covering the last `days` days.
---@param data RA.Telemetry.Data
---@param days integer
---@return table<string, integer> calls_by_key
---@return integer total
function M.since(data, days)
  local cutoff = os.date("%Y-%m-%d", os.time() - days * 86400)
  local out, total = {}, 0
  for day, keys in pairs(data.days or {}) do
    if day >= cutoff then
      for key, n in pairs(keys) do
        out[key] = (out[key] or 0) + n
        total = total + n
      end
    end
  end
  return out, total
end

---Sum the day buckets covering the `days`-day window immediately *before*
---`since(data, days)`'s own window.2 ("this week vs
---last week"). Half-open on the newer side (`day < newer_cutoff`, `since`'s
---own cutoff) so the two windows never overlap and together cover exactly
---`2 * days` days with no double-counted boundary day.
---@param data RA.Telemetry.Data
---@param days integer
---@return table<string, integer> calls_by_key
---@return integer total
function M.previous_window(data, days)
  local older_cutoff = os.date("%Y-%m-%d", os.time() - (days * 2) * 86400)
  local newer_cutoff = os.date("%Y-%m-%d", os.time() - days * 86400)
  local out, total = {}, 0
  for day, keys in pairs(data.days or {}) do
    if day >= older_cutoff and day < newer_cutoff then
      for key, n in pairs(keys) do
        out[key] = (out[key] or 0) + n
        total = total + n
      end
    end
  end
  return out, total
end

---Parse `"7d"` / `"24h"` / `7` into a day count.
---@param since string|integer|nil
---@return integer|nil
function M.parse_since(since)
  if since == nil then
    return nil
  end
  if type(since) == "number" then
    return math.max(1, math.floor(since))
  end
  local n, unit = tostring(since):match("^(%d+)%s*(%a?)")
  if not n then
    return nil
  end
  n = tonumber(n)
  if unit == "h" then
    return math.max(1, math.ceil(n / 24))
  end
  if unit == "w" then
    return n * 7
  end
  return math.max(1, n)
end

return M
