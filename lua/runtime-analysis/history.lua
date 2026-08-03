---@module 'runtime-analysis.history'
--- Request history — docs/ROADMAP.md §1.3. Persists via
--- `lib.nvim.cache.disk`, namespaced per project via
--- `lib.nvim.fs.project_key()` (the Git root of the cwd, or the cwd
--- itself), so `.http`/`.rest` collections in different repositories never
--- share one history.
---
--- **Request-only, per the roadmap entry's own stated answer to its open
--- question.** Exactly the four fields it names — method, url, status,
--- timestamp — nothing else: no headers, no body, on either side.
--- Deliberately narrower than "the request" in full: a header is very
--- often where the real secret actually lives (`Authorization: Bearer
--- ...`, the `Auth:` shorthand's own whole reason for existing), and a
--- response body can be large and can itself contain secrets from a real
--- API. Storing neither is the safe default; the roadmap entry's own
--- wording for response bodies was "behind an explicit opt-in, if at all",
--- and no opt-in for either is implemented here — a real gap this file
--- does not pretend to close silently. The url field is stored verbatim
--- and is the one remaining honest limit: a secret embedded in a query
--- string (`?api_key=...`) is not stripped, because doing so generically
--- and correctly is a real, separate problem, not a small addition to a
--- request-only history.

local disk = require("lib.nvim.cache.disk")
local project_key = require("lib.nvim.fs.project_key")

local M = {}

--- Entries are tiny (a handful of fields, no bodies) so a count cap is
--- simpler than a time-based one and just as effective — the same
--- "cardinality is bounded" discipline `runtime-analysis.telemetry`'s own
--- argument fingerprinting already applies, for the identical reason: the
--- size of this file must be a function of how much it is used, not of how
--- long ago it was started.
local MAX_ENTRIES = 200

--- Everything but these becomes `_` — the same rule
--- `runtime-analysis.telemetry.store.sanitize` already applies to its own
--- namespaces, and for the identical reason: `cache.disk` builds its path
--- as `dir .. "/" .. namespace .. ".json"` with no escaping of its own, and
--- `project_key()` returns an absolute path (slashes, drive letters,
--- colons on Windows) that would otherwise either escape the cache
--- directory or simply fail to open. Duplicated rather than required from
--- telemetry: a three-line pure-string function, and pulling in an
--- unrelated module's internal helper is worse than repeating it.
local SAFE = "[^%w%-%._]"

---@param key string
---@return string
local function sanitize(key)
  local s = tostring(key or ""):gsub(SAFE, "_")
  s = s:gsub("^%.+", "")
  if s == "" then
    s = "unnamed"
  end
  return s
end

---@return string
local function cache_key()
  return "history/" .. sanitize(project_key())
end

---Record one send attempt for the current project. Best-effort — a disk
---write failing here must never be the reason a request appears to fail;
---`disk.save`'s own `ok` return is deliberately not checked, the same
---"a report file is a convenience artifact, not data" posture
---`telemetry.report_file.write` already documents for an analogous case.
---@param method string
---@param url string
---@param status integer?
---@param note string?
---@param opts? Lib.Cache.Opts Cache dir override — real callers never need
---this (the default `stdpath("cache")`-rooted dir is what every other
---entry point in this plugin already uses); it exists so a test can point
---history at an isolated directory instead of the real cache, the same
---reason `runtime-analysis.telemetry`'s own `new({ dir = ... })` exists.
function M.record(method, url, status, note, opts)
  local key = cache_key()
  local entries = disk.load(key, opts) or {}
  -- Not `status and nil or note`: that's the classic Lua `a and b or c`
  -- trap — when `b` (here `nil`) is itself falsy, the `or c` branch always
  -- wins regardless of `a`, so `note` would never actually be dropped.
  -- Found by the spec asserting it, not by inspection.
  local final_note = nil
  if not status then
    final_note = note
  end
  entries[#entries + 1] = {
    method = method,
    url = url,
    status = status,
    note = final_note,
    at = os.time(),
  }
  if #entries > MAX_ENTRIES then
    entries = vim.list_slice(entries, #entries - MAX_ENTRIES + 1, #entries)
  end
  disk.save(key, entries, opts)
end

---This project's history, newest first — the order a picker should show
---it in, so the most likely entry to want is at the top rather than
---requiring a scroll to the bottom.
---@param opts? Lib.Cache.Opts See `M.record`'s own note on this parameter.
---@return RA.History.Entry[]
function M.list(opts)
  local entries = disk.load(cache_key(), opts) or {}
  local out = {}
  for i = #entries, 1, -1 do
    out[#out + 1] = entries[i]
  end
  return out
end

---@param opts? Lib.Cache.Opts See `M.record`'s own note on this parameter.
---@return boolean ok
function M.clear(opts)
  return disk.clear(cache_key(), opts)
end

M.MAX_ENTRIES = MAX_ENTRIES

return M
