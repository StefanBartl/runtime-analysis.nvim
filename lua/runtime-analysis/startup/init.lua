---@module 'runtime-analysis.startup'
---@brief Main-loop stall detection, on one clock with a timeline of what ran.
---@description
--- Answers "why did Neovim freeze for half a second just now", and does it in
--- the one place where the usual tools cannot: `nvim --startuptime` stops at
--- the first screen redraw and never sees a later block, and `:profile` only
--- instruments Vimscript/Lua calls, so it is blind to libuv callbacks — which
--- is exactly where filesystem work and LSP processing live.
---
--- ## How it detects a stall
---
--- A libuv timer measures its OWN lateness. Asked to fire every 20ms and
--- coming back 900ms late means the loop was blocked for 900ms, no matter what
--- blocked it — Lua, C, a subprocess, the OS. There is nothing to instrument
--- and nothing that can hide from it.
---
--- ## Why the timeline matters
---
--- "Blocked 470ms at +1.46s" names a symptom, not a cause. So every event that
--- plausibly explains a block is stamped on the same clock: each lazy.nvim
--- plugin load (with lazy's own load time AND why it loaded), `VimEnter`,
--- `VeryLazy`, `LspAttach`, LSP progress. A STALL line covers
--- `[at - blocked, at]`, so the events listed just above it are the suspects.
---
--- The load REASON is what usually cracks it: `event`/`cmd` means the plugin
--- spec intended it, while `require '<mod>' from <file>` means some other file
--- pulled the plugin in and defeated its lazy-loading — and only the second
--- case is a bug you can fix.
---
--- ## Measuring startup specifically
---
--- The timer has to tick before the config runs, which a lazily loaded plugin
--- cannot do for itself. Use the bootstrap probe, which puts this module on
--- `package.path` from its own location and needs nothing else:
---
--- ```sh
--- nvim --cmd "luafile <plugin-root>/probe/startup.lua" <file>
--- ```
---
--- `:RA startup probe` prints that exact command line, with the path filled in.
---
--- For anything after startup — "the editor hangs when I do X" — just run
--- `:RA startup start`, reproduce it, and read `:RA startup report`.

require("runtime-analysis.startup.@types")

--- Resolved lazily, and that is not a style choice: the bootstrap probe loads
--- this module via `--cmd`, before any plugin manager has run, so lib.nvim is
--- not on `package.path` yet. A top-level `require` here made the probe fail
--- outright with "module 'lib.nvim.notify' not found". By the time anything
--- actually reports, lib.nvim is there; if it somehow is not, plain
--- `vim.notify` carries the message just as well.
---@type table|nil
local _notify = nil

---@return { info: fun(msg: string), warn: fun(msg: string), error: fun(msg: string) }
local function notify_api()
  if _notify then
    return _notify
  end
  local ok, mod = pcall(require, "lib.nvim.notify")
  if ok then
    _notify = mod.create("[runtime-analysis.startup]")
  else
    local function at(level)
      return function(msg)
        vim.notify("[runtime-analysis.startup] " .. msg, level)
      end
    end
    _notify = {
      info = at(vim.log.levels.INFO),
      warn = at(vim.log.levels.WARN),
      error = at(vim.log.levels.ERROR),
    }
  end
  return _notify
end

local uv = vim.uv or vim.loop

local M = {}

---@type RA.Startup.Opts
local DEFAULTS = {
  interval_ms = 20,
  stall_ms = 80,
  duration_ms = 12000,
  log_file = "ra-startup.log",
  notify = true,
}

---@type RA.Startup.State|nil
local state = nil

---Wall-clock seconds since the run started.
---@return number
local function elapsed()
  return state and (uv.hrtime() - state.t0) / 1e9 or 0
end

---Record a timeline entry.
---@param kind RA.Startup.MarkKind
---@param text string
---@return nil
local function mark(kind, text)
  if not state then
    return
  end
  state.marks[#state.marks + 1] = { at = elapsed(), kind = kind, text = text }
end

-- ── event sources ───────────────────────────────────────────────────────────

--- Resolved on first use, never up front: when the bootstrap probe runs this,
--- lazy.nvim is not on the runtimepath yet, so an eager `require` would fail
--- and silently cost every plugin line its detail.
---@type table|false|nil
local lazy_cfg = nil

---@return table|nil
local function get_lazy_cfg()
  if lazy_cfg == nil then
    local ok, cfg = pcall(require, "lazy.core.config")
    lazy_cfg = ok and cfg or false
  end
  return lazy_cfg or nil
end

---Describe why lazy.nvim loaded a plugin, in the shape lazy records it.
---@param loaded table
---@return string|nil
local function load_reason(loaded)
  -- A `require` reason means the spec's own trigger was bypassed — the case
  -- worth acting on — so it wins over event/cmd/ft when both are present.
  if loaded.require then
    local why = "require '" .. tostring(loaded.require) .. "'"
    if loaded.source then
      why = why .. " from " .. vim.fn.fnamemodify(tostring(loaded.source), ":t")
    end
    return why
  end
  if loaded.plugin then
    return "dep of " .. tostring(loaded.plugin)
  end
  local why = loaded.event or loaded.cmd or loaded.ft or loaded.keys or loaded.start
  return why and tostring(why) or nil
end

---@param group integer
---@return nil
local function attach_sources(group)
  local au = vim.api.nvim_create_autocmd

  au("VimEnter", {
    group = group,
    callback = function()
      mark("event", "VimEnter")
    end,
  })

  au("User", {
    group = group,
    pattern = "VeryLazy",
    callback = function()
      mark("event", "VeryLazy")
    end,
  })

  au("User", {
    group = group,
    pattern = "LazyLoad",
    callback = function(ev)
      local name = tostring(ev.data)
      local detail = ""

      local cfg = get_lazy_cfg()
      local plugin = cfg and cfg.plugins[name]
      local loaded = plugin and plugin._ and plugin._.loaded

      if loaded then
        if type(loaded.time) == "number" then
          detail = (" (%.0f ms)"):format(loaded.time / 1e6)
        end
        local why = load_reason(loaded)
        if why then
          detail = detail .. "  <- " .. why
        end
      end

      mark("plugin", name .. detail)
    end,
  })

  au("LspAttach", {
    group = group,
    callback = function(ev)
      local client = vim.lsp.get_client_by_id(ev.data.client_id)
      mark("lsp", "LspAttach " .. (client and client.name or "?"))
    end,
  })

  au("LspProgress", {
    group = group,
    callback = function(ev)
      local value = ev.data and ev.data.params and ev.data.params.value
      if type(value) == "table" and value.kind == "begin" then
        mark("lsp", "progress: " .. tostring(value.title))
      end
    end,
  })
end

-- ── public API ──────────────────────────────────────────────────────────────

---@return boolean
function M.is_running()
  return state ~= nil and state.timer ~= nil
end

---Begin a measurement run. Restarts a run that is already in progress.
---@param opts RA.Startup.Opts|nil
---@return boolean started
function M.start(opts)
  opts = vim.tbl_extend("force", DEFAULTS, opts or {})

  if M.is_running() then
    M.stop()
  end

  local group = vim.api.nvim_create_augroup("RuntimeAnalysisStartup", { clear = true })

  state = {
    t0 = uv.hrtime(),
    last = uv.hrtime(),
    marks = {},
    opts = opts,
    group = group,
    timer = nil,
  }

  attach_sources(group)

  local timer = uv.new_timer()
  if not timer then
    notify_api().error("could not create the timer")
    state = nil
    return false
  end
  state.timer = timer

  timer:start(opts.interval_ms, opts.interval_ms, function()
    if not state then
      return
    end
    local now = uv.hrtime()
    local late = (now - state.last) / 1e6 - opts.interval_ms
    state.last = now
    if late >= opts.stall_ms then
      -- `at` is when the block ENDED; it covers [at - late, at].
      state.marks[#state.marks + 1] = {
        at = (now - state.t0) / 1e9,
        kind = "stall",
        text = "",
        late = late,
      }
    end
  end)

  -- A run of 0 keeps measuring until `stop()`/`report()` — for "reproduce the
  -- hang, then look", where nobody knows in advance how long that takes.
  if opts.duration_ms and opts.duration_ms > 0 then
    vim.defer_fn(function()
      if M.is_running() then
        M.report()
      end
    end, opts.duration_ms)
  end

  return true
end

---Stop measuring. The collected marks stay available for `report()`.
---@return nil
function M.stop()
  if state and state.timer then
    state.timer:stop()
    if not state.timer:is_closing() then
      state.timer:close()
    end
    state.timer = nil
  end
  if state and state.group then
    pcall(vim.api.nvim_del_augroup_by_id, state.group)
    state.group = nil
  end
end

---The collected timeline as report lines.
---@return string[] lines
---@return integer count  number of stalls
---@return number total_ms  total blocked time
function M.lines()
  if not state then
    return { "no measurement has run yet — :RA startup start" }, 0, 0
  end

  local marks = vim.deepcopy(state.marks)
  table.sort(marks, function(a, b)
    return a.at < b.at
  end)

  local out = {
    ("=== timeline + stalls >= %d ms (%.0f s) ==="):format(
      state.opts.stall_ms,
      elapsed()
    ),
    "  a STALL line covers [at - blocked, at] — read the events just above it",
    "",
  }

  local total, count = 0, 0
  for _, m in ipairs(marks) do
    if m.kind == "stall" then
      total = total + m.late
      count = count + 1
      out[#out + 1] = ("  +%6.2f s  ***** STALL  blocked %6.0f ms  (from +%.2f s)"):format(
        m.at,
        m.late,
        m.at - m.late / 1000
      )
    else
      out[#out + 1] = ("  +%6.2f s  %-7s %s"):format(m.at, m.kind, m.text)
    end
  end

  out[#out + 1] = ""
  if count == 0 then
    out[#out + 1] = "  no stalls — the loop stayed responsive"
  else
    out[#out + 1] = ("  ---- %d stall(s), %.0f ms blocked in total"):format(count, total)
  end

  return out, count, total
end

---Stop the run and present the timeline (notification plus log file).
---@return string[] lines
function M.report()
  local was_running = M.is_running()
  M.stop()

  local lines, count = M.lines()

  if state and state.opts.log_file and state.opts.log_file ~= "" then
    pcall(vim.fn.writefile, lines, state.opts.log_file)
  end

  if state and state.opts.notify and was_running then
    notify_api().warn(table.concat(lines, "\n"))
  end

  local _ = count
  return lines
end

---Clear the collected marks and any running measurement.
---@return nil
function M.reset()
  M.stop()
  state = nil
end

---The `--cmd` line that measures a startup, with this plugin's path filled in.
---@return string
function M.probe_command()
  -- This file is <root>/lua/runtime-analysis/startup/init.lua; the probe lives
  -- at <root>/probe/startup.lua.
  local src = debug.getinfo(1, "S").source:sub(2)
  local root = vim.fn.fnamemodify(src, ":h:h:h:h")
  local probe = root .. "/probe/startup.lua"
  return ('nvim --cmd "luafile %s" <file>'):format(probe)
end

return M
