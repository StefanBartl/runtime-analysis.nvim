---@module 'runtime-analysis.history'
--- Request history — Persists via
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
local notify = require("lib.nvim.notify").create("[runtime-analysis]")

local M = {}

--- Entries are tiny (a handful of fields, no bodies) so a count cap is
--- simpler than a time-based one and just as effective — the same
--- "cardinality is bounded" discipline `runtime-analysis.telemetry`'s own
--- argument fingerprinting already applies, for the identical reason: the
--- size of this file must be a function of how much it is used, not of how
--- long ago it was started.
---How many past requests the history file keeps.
---
---`history_max_entries`: the ring size is a preference about how far back
---`:RAHistory` should reach, and the discipline it protects -- "the file's
---size is a function of use, not of age" -- holds at any bound.
---@return integer
local function max_entries()
  local ok, ra = pcall(require, "runtime-analysis")
  if not ok then
    return 200
  end
  local n = (ra.opts or {}).history_max_entries
  return (type(n) == "number" and n > 0) and n or 200
end

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

---@internal
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

---@internal
---@param root? string Absolute repository root — see `M.list`'s own
---doc-comment for why a reader (unlike a recorder) sometimes needs one
---other than cwd.
---@return string
local function cache_key(root)
  return "history/" .. sanitize(project_key(root))
end

---Load this project's stored entries, distinguishing "no file yet" from
---"file exists but failed to decode" (ERR-11) — the same shape
---`runtime-analysis.env`'s own `read_env_file` already returns for the
---identical reason. Both `M.record` and `M.list` are a load-*-save cycle
---or a plain read on top of the same file, and `disk.load` itself already
---backs up the original bytes to `<path>.corrupt` once on a decode
---failure -- this only carries that distinction one level up instead of
---collapsing it back into a silently-empty list.
---@internal
---@param key string
---@param opts? Lib.Cache.Opts
---@return RA.History.Entry[] entries empty when missing *or* corrupt
---@return string? err set only when the file exists but could not be decoded
local function read_entries(key, opts)
  local entries, err = disk.load(key, opts)
  return entries or {}, err
end

---Record one send attempt for the current project. Best-effort — a disk
---write failing here must never be the reason a request appears to fail;
---`disk.save`'s own `ok` return is deliberately not checked, the same
---"a report file is a convenience artifact, not data" posture
---`telemetry.report_file.write` already documents for an analogous case.
---
---That posture covers the *write* only. The *read* that starts this
---load-modify-save cycle is different: a corrupt history file must not
---silently reset to a single-entry list with nothing said about it (ERR-11)
----- the original bytes are safe (`disk.load` already backed them up), but
---the live file this project's `:RA history` reads from is about to be
---overwritten all the same, so this warns once rather than staying silent.
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
  local entries, load_err = read_entries(key, opts)
  if load_err then
    notify.warn(
      ("this project's request history was unreadable and is being rebuilt; the original file was kept as a backup (%s)"):format(
        load_err
      )
    )
  end
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
  local cap = max_entries()
  if #entries > cap then
    entries = vim.list_slice(entries, #entries - cap + 1, #entries)
  end
  disk.save(key, entries, opts)
end

---This project's history, newest first — the order a picker should show
---it in, so the most likely entry to want is at the top rather than
---requiring a scroll to the bottom.
---
---`opts.root`, unlike `M.record`, is a real feature here rather than a
---test-only escape hatch: `M.record` always writes for wherever the reader
---is *currently working* (cwd), which is the only sensible meaning for "I
---just sent a request" — but a cross-repo reader (documentation.nvim's own
---endpoint-coverage join) analyzes a tree via
---`opts.root`, which is not necessarily cwd at all, and needs *that*
---project's history, not whichever one Neovim happens to be sitting in.
---@param opts? Lib.Cache.Opts|{ root?: string } `root` overrides the
---project key (default cwd, via `project_key()`); the rest is `M.record`'s
---own cache-dir override, unchanged.
---@return RA.History.Entry[] entries empty both when nothing was ever
---recorded and when the file exists but failed to decode — check `err` to
---tell the two apart (ERR-11).
---@return string? err set only when the history file exists but could not
---be decoded; `nil` (including when `entries` is empty) means genuinely no
---history yet.
function M.list(opts)
  opts = opts or {}
  local entries, err = read_entries(cache_key(opts.root), opts)
  local out = {}
  for i = #entries, 1, -1 do
    out[#out + 1] = entries[i]
  end
  return out, err
end

---@param opts? Lib.Cache.Opts|{ root?: string } See `M.list`'s own note on `root`.
---@return boolean ok
function M.clear(opts)
  opts = opts or {}
  return disk.clear(cache_key(opts.root), opts)
end

---Where this project's history actually lives on disk. Mirrors
---`telemetry.store.data_path`'s own reasoning and the same disclaimer:
---nothing in this module reads it, it exists so a caller (or a test
---exercising the ERR-11 corrupt-file path) can find the file `M.record`/
---`M.list` resolve to without duplicating `cache_key`'s own sanitizing and
---project-keying logic.
---@param opts? Lib.Cache.Opts|{ root?: string } See `M.list`'s own note on `root`.
---@return string
function M.data_path(opts)
  opts = opts or {}
  local dir = opts.dir or (vim.fn.stdpath("cache") .. "/lib.nvim/cache")
  return dir .. "/" .. cache_key(opts.root) .. ".json"
end

--- The effective cap, for tests and for anything that wants to say what it
--- is. A function rather than the old `M.MAX_ENTRIES` constant, because the
--- answer now depends on `setup({ history_max_entries = N })`.
---@return integer
M.max_entries = max_entries

return M
