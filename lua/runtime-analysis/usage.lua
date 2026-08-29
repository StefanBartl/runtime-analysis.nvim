---@module 'runtime-analysis.usage'
--- Keymap and command usage — Which of your own
--- mappings and commands you actually press. The honest use case is
--- pruning: a config accumulates bindings for years, and nothing ever
--- tells you which ones went cold.
---
--- **The one real caveat, stated up front because it shapes everything
--- else here.** This is the first thing in this plugin that records *what
--- the person did* rather than *what the code did* — every other feature
--- (telemetry, startup attribution, cost-vs-use) counts function calls;
--- this counts keypresses and typed commands. It stays local (the same
--- "no account, no upload, no aggregation service" posture
--- the "Deliberately not building" table already
--- states for telemetry), stays opt-in (nothing here runs until `M.start()`
--- is called explicitly), and must never grow a "share this" feature.
---
--- Mechanically reuses `runtime-analysis.telemetry`'s own machinery rather
--- than inventing a second persistence layer: one real telemetry instance
--- underneath, `inst.wrap_fn` for keymaps (a keymap callback is a real Lua
--- function, wrapped exactly once at `vim.keymap.set()` time — the
--- mechanism's own intended usage, not a workaround). Commands have no
--- such function to intercept — `:Telescope find_files` is text typed at a
--- prompt, not a call this plugin could hook before it happens — so a
--- `CmdlineLeave` autocmd reads what was actually typed (only when the
--- command line was not aborted) and records it through the *same*
--- instance, `wrap_fn`'d exactly once per distinct command name and
--- re-invoked on every subsequent press of it — never re-wrapped per
--- press, which would otherwise leak a fresh registry site on every
--- keystroke.
---
--- **Honest limits:**
--- - Only `vim.keymap.set` calls made *after* `M.start()` are ever seen —
---   same "only what runs after this starts" limit `telemetry.startup`
---   already states for `require`.
--- - Only *function*-callback keymaps are tracked. `vim.keymap.set('n',
---   'x', ':SomeCommand<CR>')` (a string rhs) has nothing to wrap; if
---   `SomeCommand` itself goes through `:`, the command hook below may
---   still see it, but the keymap that triggered it will not be counted.
--- - A keymap's key is `"mode lhs"` — a buffer-local mapping sharing that
---   exact mode+lhs with a different mapping elsewhere (different buffer,
---   different filetype) is combined into one count, not tracked per-buffer.
--- - A typed command's name is extracted heuristically (stripping a
---   leading range/count and a trailing `!`) — an unusual range syntax may
---   occasionally misparse it.

local telemetry = require("runtime-analysis.telemetry")

local M = {}

---@type RA.Telemetry.Instance?
local inst = nil
---@type fun(mode: string|string[], lhs: string, rhs: string|function, opts?: table)?
local original_keymap_set = nil
---@type table<string, function>
local wrapped_commands = {}
local augroup = nil

---@internal
---@param mode string|string[]
---@return string
local function mode_key(mode)
  return type(mode) == "table" and table.concat(mode, ",") or mode
end

---@internal
---@param mode string|string[]
---@param lhs string
---@param rhs string|function
---@param opts? table
local function wrap_keymap_set(mode, lhs, rhs, opts)
  if type(rhs) == "function" and inst then
    rhs = inst.wrap_fn(rhs, ("keymap %s %s"):format(mode_key(mode), lhs))
  end
  return original_keymap_set(mode, lhs, rhs, opts)
end

---Record one press of `name`, wrapping a trivial no-op through `inst`
---exactly once per distinct command name — never once per press. `wrap_fn`
---creates a brand-new registry site on every call; calling it on every
---keypress would leak one site per press instead of counting through a
---single stable one, the same "wrap once, call many times" discipline a
---real keymap callback already gets for free.
---@internal
---@param name string
local function record_command(name)
  local record = wrapped_commands[name]
  if not record then
    record = inst.wrap_fn(function() end, "command " .. name)
    wrapped_commands[name] = record
  end
  record()
end

---A typed command line's own bare name — a leading range/count (`%`,
---`.,+3`, `5`, marks, ...) stripped heuristically, a trailing `!` excluded
---by construction (word characters stop before it), so `:w!` and `:w`
---share one key — a bang is a modifier on the same command, not a
---different one.
---@internal
---@param line string
---@return string?
local function command_name(line)
  return line:match("^%s*[%d,.$'<>%+%-]*%s*(%a[%w_]*)")
end

---Start counting. Idempotent — a second call while already running is a
---no-op, the same posture every other `start()` in this plugin takes.
---@param opts? { namespace?: string, persist?: boolean, dir?: string }
---@return boolean started
function M.start(opts)
  if inst then
    return false
  end
  opts = opts or {}

  inst = telemetry.new({
    namespace = opts.namespace or "runtime-analysis.usage",
    persist = opts.persist,
    dir = opts.dir,
  })
  -- Must run before any `wrap_fn` call below — a target added while the
  -- instance is not yet running is registered but not attached, and
  -- would count nothing until some later `start()` picked it up. Calling
  -- this now, before a single keymap or command exists to wrap, means
  -- every `wrap_fn` from here on attaches immediately.
  inst.start()

  wrapped_commands = {}
  original_keymap_set = vim.keymap.set
  vim.keymap.set = wrap_keymap_set

  -- Raw augroup rather than autocmd.group(): M.stop() below deletes it by id
  -- and M.start() may run again later, and autocmd.group()'s name->id cache
  -- would keep handing back the deleted id instead of a fresh one.
  augroup = vim.api.nvim_create_augroup("runtime_analysis_usage", { clear = true })
  require("lib.nvim.bindings.autocmd").create("CmdlineLeave", function()
    if vim.v.event.abort or vim.fn.getcmdtype() ~= ":" then
      return
    end
    local name = command_name(vim.fn.getcmdline())
    if name then
      record_command(name)
    end
  end, {
    group = augroup,
    desc = "runtime-analysis.usage: count a typed command, unless the cmdline was aborted",
  })

  return true
end

---Stop counting and restore `vim.keymap.set`. Keeps everything collected
---so far — `M.report()` stays readable afterward. Idempotent.
---@return boolean stopped
function M.stop()
  if not inst then
    return false
  end
  vim.keymap.set = original_keymap_set
  original_keymap_set = nil
  if augroup then
    vim.api.nvim_del_augroup_by_id(augroup)
    augroup = nil
  end
  inst.stop()
  inst = nil
  wrapped_commands = {}
  return true
end

---@return boolean
function M.is_running()
  return inst ~= nil
end

---@param report_opts? RA.Telemetry.ReportOpts
---@return RA.Telemetry.Report?
function M.report(report_opts)
  return inst and inst.report(report_opts)
end

---@param report_opts? RA.Telemetry.ReportOpts
---@return string[]
function M.lines(report_opts)
  if not inst then
    return { "runtime-analysis.usage is not running — call M.start() first" }
  end
  return inst.lines(report_opts)
end

---@param report_opts? RA.Telemetry.ReportOpts
---@return string[]
function M.markdown(report_opts)
  if not inst then
    return { "_(runtime-analysis.usage is not running)_" }
  end
  return inst.markdown(report_opts)
end

return M
