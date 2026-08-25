-- TESTS/config_validate_spec.lua — runtime-analysis.config.validate
-- (REVIEW.md §1 "Config-Merge-Reihenfolge"): a typo'd opts key must warn,
-- with a "did you mean" guess when one is close enough, and must never
-- block the caller it validates for.

return function(H)
  local eq, ok = H.eq, H.ok
  local validate = require("runtime-analysis.config.validate")

  -- A tiny stub notifier -- the same shape `lib.nvim.notify.create()`
  -- returns, minus everything `M.check` never calls.
  local function stub_notify()
    local calls = {}
    return {
      warn = function(msg)
        calls[#calls + 1] = msg
      end,
    }, calls
  end

  -- Direct unit tests of M.check ------------------------------------------

  do
    local notify, calls = stub_notify()
    validate.check({ a = 1, b = 2 }, { "a", "b", "c" }, "ctx", notify)
    eq(#calls, 0, "check: every key known -> no warning")
  end

  do
    local notify, calls = stub_notify()
    validate.check(nil, { "a" }, "ctx", notify)
    eq(#calls, 0, "check: opts == nil -> no-op, not an error")
  end

  do
    local notify, calls = stub_notify()
    -- "slpit" is one transposition away from "split" -- well inside the
    -- suggestion threshold.
    validate.check({ slpit = "vsplit" }, { "split", "request_filetype" }, "ctx", notify)
    eq(#calls, 1, "check: one unknown key -> exactly one warning")
    ok(calls[1]:find('"slpit"', 1, true) ~= nil, "check: warning names the actual unknown key")
    ok(
      calls[1]:find('did you mean "split"?', 1, true) ~= nil,
      "check: a close key is suggested by name"
    )
  end

  do
    local notify, calls = stub_notify()
    -- Nothing in `known` is remotely close to "zzzzzz" -- no suggestion
    -- should be attached, rather than a misleading nearest-of-a-bad-lot guess.
    validate.check({ zzzzzz = true }, { "split", "request_filetype" }, "ctx", notify)
    eq(#calls, 1, "check: one warning for a key with no close match either")
    ok(calls[1]:find('"zzzzzz"', 1, true) ~= nil, "check: the unrecognized key is still named")
    ok(
      calls[1]:find("did you mean", 1, true) == nil,
      "check: no 'did you mean' when nothing is actually close"
    )
  end

  do
    local notify, calls = stub_notify()
    -- Two unknown keys at once -- one warning, not two (no per-item spam),
    -- both keys present, sorted.
    validate.check(
      { zzzzzz = true, slpit = "vsplit" },
      { "split", "request_filetype" },
      "ctx",
      notify
    )
    eq(#calls, 1, "check: several unknown keys -> still exactly one warning")
    ok(calls[1]:find('"slpit"', 1, true) ~= nil, "check: first unknown key present")
    ok(calls[1]:find('"zzzzzz"', 1, true) ~= nil, "check: second unknown key present")
  end

  -- Wiring: the three real setup() boundaries ------------------------------
  -- Fail-open, end to end: each call below must both warn AND still leave
  -- the caller fully functional -- a typo degrades to "warned, defaults
  -- applied", never to "setup aborted".

  local function with_vim_notify(fn)
    local captured
    local orig = vim.notify
    vim.notify = function(msg, level)
      captured = { msg = msg, level = level }
    end
    fn()
    vim.notify = orig
    return captured
  end

  do
    local ra = require("runtime-analysis")
    local captured = with_vim_notify(function()
      ra.setup({ slpit = "vsplit" })
    end)
    ok(
      captured and captured.msg:find('"slpit"', 1, true) ~= nil,
      "runtime-analysis.setup(): a typo'd top-level key warns through the real notifier"
    )
    ok(
      captured and captured.msg:find('did you mean "split"?', 1, true) ~= nil,
      "runtime-analysis.setup(): the warning suggests the real key"
    )
    -- Still fully functional despite the typo -- commands registered, no error.
    local cmds = vim.api.nvim_get_commands({})
    ok(cmds.RA ~= nil, "runtime-analysis.setup(): still completes setup despite the typo")
  end

  do
    local telemetry = require("runtime-analysis.telemetry")
    local tmpdir = vim.fn.tempname() .. "-config-validate"
    local captured = with_vim_notify(function()
      telemetry.new({
        namespace = "spec.config_validate.new",
        persist = true,
        dir = tmpdir,
        max_arg_value = 10, -- typo for max_arg_values
      })
    end)
    ok(
      captured and captured.msg:find('"max_arg_value"', 1, true) ~= nil,
      "telemetry.new(): a typo'd opts key warns through the real notifier"
    )
    ok(
      captured and captured.msg:find('did you mean "max_arg_values"?', 1, true) ~= nil,
      "telemetry.new(): the warning suggests the real key"
    )
    ok(
      telemetry.get("spec.config_validate.new") ~= nil,
      "telemetry.new(): still creates a working instance despite the typo"
    )
  end

  do
    local lazy_adapter = require("runtime-analysis.telemetry.lazy")
    local captured = with_vim_notify(function()
      lazy_adapter.setup({
        plugins = {
          ["someorg/config-validate-spec.nvim"] = {
            namespace = "spec.config_validate.lazy",
            profil_args = true, -- typo for profile_args
          },
        },
      })
    end)
    ok(
      captured and captured.msg:find('"profil_args"', 1, true) ~= nil,
      "telemetry.lazy.setup(): a typo'd per-plugin key warns through the real notifier"
    )
    ok(
      captured and captured.msg:find('did you mean "profile_args"?', 1, true) ~= nil,
      "telemetry.lazy.setup(): the warning suggests the real key"
    )
    -- pcall, not a bare call: whether this errors is exactly what "still
    -- functional despite the typo" means here -- lazy.nvim itself may or may
    -- not be stubbed in package.loaded by the time this spec runs.
    local setup_ok = pcall(lazy_adapter.setup, {
      plugins = {
        ["someorg/config-validate-spec.nvim"] = { namespace = "spec.config_validate.lazy2" },
      },
    })
    ok(setup_ok, "telemetry.lazy.setup(): a typo earlier does not leave the adapter broken")
  end
end
