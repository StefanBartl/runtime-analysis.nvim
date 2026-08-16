---@module 'runtime-analysis.config.validate'
--- Unknown-key ("did you mean") validation for `opts` tables, run once
--- before any merge — `LUA_NVIM.md`'s "Config- und Merge-Sicherheit": a
--- typo in a nested option (`profil_args` for `profile_args`) currently
--- vanishes silently into whatever the default already was, with no signal
--- anywhere that the key was never read. Fail-open by design: an unknown
--- key gets exactly one warning, never blocks `setup()` — the same posture
--- LUA_NVIM.md's own Fail-Open section takes for a single bad config value.

local dist = require("lib.lua.strings.distance")

local M = {}

--- Below this similarity score, a typo'd key is reported as "unknown"
--- with no guess attached rather than a misleading suggestion — e.g.
--- "namespece" (score 0.89 against "namespace") clears it easily, an
--- unrelated key like "foo" does not clear it against anything.
local SUGGEST_THRESHOLD = 0.6

---Closest entry in `known` to `key`, or `nil` when nothing clears
---`SUGGEST_THRESHOLD`.
---@internal
---@param key string
---@param known string[]
---@return string?
local function best_match(key, known)
  local best, best_score = nil, 0
  for _, candidate in ipairs(known) do
    local score = dist.similarity(key, candidate)
    if score > best_score then
      best, best_score = candidate, score
    end
  end
  if best and best_score >= SUGGEST_THRESHOLD then
    return best
  end
  return nil
end

---Warn once about any string key in `opts` that is not in `known` —
---called before a caller merges `opts` over its own defaults, never after.
---A no-op when `opts` is not a table (the normal "no opts passed" case) or
---every key is recognized.
---@param opts table?
---@param known string[] The exact field names this `opts` table accepts
---@param label string Identifies the boundary in the warning, e.g. `"runtime-analysis.setup()"`
---@param notify Lib.Notify.Notifier
---@return nil
function M.check(opts, known, label, notify)
  if type(opts) ~= "table" then
    return
  end

  local known_set = {}
  for _, k in ipairs(known) do
    known_set[k] = true
  end

  local unknown = {}
  for k in pairs(opts) do
    if type(k) == "string" and not known_set[k] then
      unknown[#unknown + 1] = k
    end
  end
  if #unknown == 0 then
    return
  end
  table.sort(unknown)

  local parts = {}
  for _, k in ipairs(unknown) do
    local guess = best_match(k, known)
    if guess then
      parts[#parts + 1] = ("%q (did you mean %q?)"):format(k, guess)
    else
      parts[#parts + 1] = ("%q"):format(k)
    end
  end

  notify.warn(("%s: unknown option key(s): %s"):format(label, table.concat(parts, ", ")))
end

return M
