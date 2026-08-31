-- Test code: when something here comes back nil -- a `pcall(require, ...)`,
-- a fixture read, a uv handle -- this file must crash and name it. The nil
-- guards LuaLS asks for below would hide the very failure it exists to report.
---@diagnostic disable: need-check-nil
-- TESTS/usage_spec.lua — runtime-analysis.usage
--
-- Real `vim.keymap.set` calls and a real typed command line (via
-- `nvim_feedkeys`), not stubs — the same "exercise the real thing" posture
-- provenance_spec.lua already takes, since this module's whole point is
-- intercepting those two real entry points. `persist = false` throughout:
-- this is `runtime-analysis.telemetry` underneath, and a persisted spec run
-- would otherwise leave a stray cache file behind (see the module's own
-- `M.start` doc-comment on why `persist` is left overridable at all).
--
-- **What is not tested here, and why.** The module reads `v:event.abort`
-- to skip an aborted (`<Esc>`-cancelled) command line. Reproducing a real
-- abort through `nvim_feedkeys` in a headless instance turned out to be
-- unreliable while writing this spec — `<Esc>` there executed the typed
-- command rather than cancelling it (a property of the headless/feedkeys
-- combination, verified by checking the *global variable* the fed command
-- set, not an assumption). Rather than assert against behavior this
-- environment cannot actually produce, the early-return guard this branch
-- shares (`getcmdtype() ~= ":"`) is tested directly instead: a stray
-- `CmdlineLeave` firing with no real command line active — the same shape
-- an aborted one would leave `getcmdtype()` in — must record nothing.

return function(H)
  local eq, ok = H.eq, H.ok
  local usage = require("runtime-analysis.usage")

  ---@param lhs string
  ---@return function? callback the live callback nvim itself now holds
  local function get_callback(lhs)
    for _, m in ipairs(vim.api.nvim_get_keymap("n")) do
      if m.lhs == lhs and m.callback then
        return m.callback
      end
    end
    return nil
  end

  -- Lifecycle: idempotent both ways, matching every other `start()`/`stop()`
  -- in this plugin.
  do
    eq(usage.is_running(), false, "not running before the first start()")
    eq(usage.start({ persist = false }), true, "start(): first call starts")
    eq(usage.is_running(), true, "is_running() true once started")
    eq(usage.start({ persist = false }), false, "start(): second call while running is a no-op")
    eq(usage.stop(), true, "stop(): stops a running instance")
    eq(usage.is_running(), false, "is_running() false after stop")
    eq(usage.stop(), false, "stop(): second call while stopped is a no-op")
  end

  -- report()/lines()/markdown() before any start(): a clear "not running"
  -- state, never an error.
  do
    eq(usage.report(), nil, "report() returns nil when not running")
    local lines = usage.lines()
    eq(#lines, 1, "lines(): one explanatory line when not running")
    ok(lines[1]:find("not running", 1, true) ~= nil, "lines(): explains it is not running")
    local md = usage.markdown()
    eq(#md, 1, "markdown(): one explanatory line when not running")
    ok(md[1]:find("not running", 1, true) ~= nil, "markdown(): explains it is not running")
  end

  -- A function-callback keymap set after start() is wrapped, and pressing
  -- it still runs the real callback — counting must never change behavior.
  do
    usage.start({ persist = false })
    local calls = 0
    vim.keymap.set("n", "ZZraUsageSpecA", function()
      calls = calls + 1
    end)

    local cb = get_callback("ZZraUsageSpecA")
    ok(cb ~= nil, "the mapping is retrievable with a real callback installed")
    cb()
    eq(calls, 1, "invoking the (wrapped) mapping still runs the real callback")

    local before = usage.report().total_calls
    cb()
    local after = usage.report().total_calls
    eq(calls, 2, "a second press still runs the real callback")
    ok(after > before, "a second press is counted too")

    vim.keymap.del("n", "ZZraUsageSpecA")
    usage.stop()
  end

  -- A string-rhs keymap has no function to wrap. Documented as an honest
  -- limit in the module's own doc-comment — the only thing worth asserting
  -- here is that setting one is not an error.
  do
    usage.start({ persist = false })
    ok(
      pcall(vim.keymap.set, "n", "ZZraUsageSpecB", "<Nop>"),
      "a string-rhs keymap sets without error while usage tracking is running"
    )
    vim.keymap.del("n", "ZZraUsageSpecB")
    usage.stop()
  end

  -- A real typed command, committed with <CR> through a genuine cmdline
  -- session, is counted through the CmdlineLeave hook.
  do
    usage.start({ persist = false })
    local before = usage.report().total_calls

    vim.api.nvim_feedkeys(
      vim.api.nvim_replace_termcodes(":let g:__ra_usage_spec = 1<CR>", true, false, true),
      "x",
      false
    )

    local after = usage.report().total_calls
    ok(after > before, "a real typed command is counted")
    eq(vim.g.__ra_usage_spec, 1, "the fed command actually ran (sanity check on the test itself)")

    vim.g.__ra_usage_spec = nil
    usage.stop()
  end

  -- The early-return guard (`getcmdtype() ~= ":"`) that also protects the
  -- abort case: a `CmdlineLeave` firing with no real command line active
  -- must record nothing, not error.
  do
    usage.start({ persist = false })
    eq(vim.fn.getcmdtype(), "", "sanity check: no cmdline is active in this spec process")
    local before = usage.report().total_calls

    ok(
      pcall(vim.api.nvim_exec_autocmds, "CmdlineLeave", {}),
      "a stray CmdlineLeave with no active cmdline does not error"
    )

    local after = usage.report().total_calls
    eq(after, before, "... and records nothing")

    usage.stop()
  end

  -- stop() restores the real vim.keymap.set — a later keymap is never
  -- silently wrapped once tracking has ended.
  do
    local original = vim.keymap.set
    usage.start({ persist = false })
    ok(vim.keymap.set ~= original, "vim.keymap.set is replaced while running")
    usage.stop()
    eq(vim.keymap.set, original, "vim.keymap.set is restored exactly after stop()")
  end
end
