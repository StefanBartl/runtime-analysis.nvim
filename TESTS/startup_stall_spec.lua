-- TESTS/startup_stall_spec.lua — `runtime-analysis.startup`, the main-loop
-- stall detector (`:RA startup start`/`report`). Not to be confused with
-- `runtime-analysis.telemetry.startup` (the require-load waterfall), which
-- `startup_spec.lua` already covers.
--
-- ERR-22 regression: `M.start(opts)` builds `state.opts` via a plain
-- `vim.tbl_extend("force", DEFAULTS, opts or {})` with no value-level check
-- on the numeric fields — `interval_ms` reaches `timer:start()` directly (in
-- `M.start()` itself), `duration_ms` a `> 0` comparison (also in `M.start()`
-- itself), and `stall_ms` a `>=` comparison on every tick of the timer
-- callback started right there. A wrong-TYPE value (a typo'd string) used to
-- throw on whichever of those it reached first instead of degrading to its
-- documented default. See `numeric_field` in lua/runtime-analysis/startup/
-- init.lua.

return function(H)
  local eq, ok = H.eq, H.ok
  local startup = require("runtime-analysis.startup")

  ---@param opts table
  ---@return string[] warned messages
  local function start_and_capture_warnings(opts)
    local warned = {}
    local orig_notify = vim.notify
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(msg, level)
      warned[#warned + 1] = { msg = msg, level = level }
    end
    ---@diagnostic disable-next-line: assign-type-mismatch
    local started = startup.start(opts)
    vim.notify = orig_notify
    return warned, started
  end

  do
    local warned, started = start_and_capture_warnings({ interval_ms = "often" })
    ok(started, "ERR-22: a non-numeric interval_ms still starts")
    ok(#warned >= 1, "ERR-22: a non-numeric interval_ms warns")
    startup.stop()
  end

  do
    local warned, started = start_and_capture_warnings({ stall_ms = "big" })
    ok(started, "ERR-22: a non-numeric stall_ms still starts")
    ok(#warned >= 1, "ERR-22: a non-numeric stall_ms warns")
    -- The coerced value (falls back to the documented default, 80) is what
    -- downstream reads, not the raw string — `M.lines()`'s own header
    -- formats it with `%d`, which would itself throw on a non-number.
    local lines = startup.lines()
    ok(lines[1]:find("80 ms", 1, true) ~= nil, "stall_ms falls back to its default (80)")
    startup.stop()
  end

  do
    local warned, started = start_and_capture_warnings({ duration_ms = "soon" })
    ok(started, "ERR-22: a non-numeric duration_ms still starts")
    ok(#warned >= 1, "ERR-22: a non-numeric duration_ms warns")
    startup.stop()
  end

  -- A numeric STRING is accepted outright, with no warning — `numeric_field`
  -- coerces it via `tonumber`, the same leniency `telemetry/init.lua`'s own
  -- copy of this idiom has.
  do
    local warned, started = start_and_capture_warnings({ interval_ms = "15" })
    ok(started, "numeric_field: a numeric string still starts")
    eq(#warned, 0, "numeric_field: a numeric string does not warn")
    startup.stop()
  end

  -- Unknown-key validation (ERR-50): `M.start()` did not call
  -- `config_validate.check` at all before this fix — a typo'd key vanished
  -- silently into an ignored field instead of ever being read.
  do
    local warned = start_and_capture_warnings({ intervall_ms = 5 })
    ok(#warned >= 1, "unknown option key warns")
    ok(
      warned[1].msg:find("intervall_ms", 1, true) ~= nil
        and warned[1].msg:find("interval_ms", 1, true) ~= nil,
      "unknown key warning names the typo and suggests the real key"
    )
    startup.stop()
  end

  startup.reset()
end
