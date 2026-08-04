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

return M
