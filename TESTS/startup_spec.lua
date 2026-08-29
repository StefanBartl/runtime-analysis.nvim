-- TESTS/startup_spec.lua — runtime-analysis.telemetry.startup
--
-- Real module loads against real files on disk: a temp directory added to
-- `package.path`, so `require` genuinely misses the cache, genuinely reads a
-- file, and genuinely nests — the only honest way to test that self time
-- excludes children, since a stubbed `require` would prove nothing about
-- the wrapper's own stack discipline.

return function(H)
  local eq, ok = H.eq, H.ok
  local startup = require("runtime-analysis.telemetry.startup")

  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")

  ---@param name string
  ---@param body string
  local function write_module(name, body)
    local f = assert(io.open(dir .. "/" .. name .. ".lua", "w"))
    f:write(body)
    f:close()
  end

  -- A leaf that burns a measurable amount of time, and a parent that
  -- requires it — so `self_ms` has something real to exclude.
  write_module(
    "ra_spec_leaf",
    [[
      local x = 0
      for i = 1, 200000 do x = x + i end
      return { x = x }
    ]]
  )
  write_module(
    "ra_spec_parent",
    [[
      local leaf = require("ra_spec_leaf")
      return { leaf = leaf }
    ]]
  )
  write_module("ra_spec_boom", [[ error("module raised during load", 0) ]])

  local saved_path = package.path
  package.path = dir .. "/?.lua;" .. package.path

  -- Nothing recorded before start().
  do
    startup.reset()
    local report = startup.report()
    eq(#report.modules, 0, "startup: nothing recorded before start()")
    eq(report.running, false, "startup: not running before start()")
  end

  -- start()/stop() lifecycle, and that `require` is genuinely restored.
  do
    startup.reset()
    local before = require
    eq(startup.start(), true, "startup.start: returns true the first time")
    eq(startup.start(), false, "startup.start: idempotent — false when already running")
    ok(require ~= before, "startup.start: the global require is actually wrapped")
    eq(startup.is_running(), true, "startup.is_running: true while running")

    eq(startup.stop(), true, "startup.stop: returns true when it was running")
    eq(startup.stop(), false, "startup.stop: idempotent — false when already stopped")
    eq(require, before, "startup.stop: the original require is restored exactly")
  end

  -- The real measurement: a parent requiring a leaf. Both are recorded, the
  -- parent's self time excludes the leaf, and the leaf's does not.
  do
    startup.reset()
    package.loaded.ra_spec_leaf = nil
    package.loaded.ra_spec_parent = nil

    startup.start()
    local parent = require("ra_spec_parent")
    startup.stop()

    ok(
      parent ~= nil and parent.leaf ~= nil,
      "startup: the module still loads correctly through the wrapper"
    )

    local by_name = {}
    for _, e in ipairs(startup.report().modules) do
      by_name[e.modname] = e
    end

    ok(by_name.ra_spec_parent ~= nil, "startup: the parent module was recorded")
    ok(by_name.ra_spec_leaf ~= nil, "startup: the nested leaf module was recorded too")

    local p, l = by_name.ra_spec_parent, by_name.ra_spec_leaf
    ok(l.self_ms > 0, "startup: the leaf's self time is a real, positive measurement")
    ok(
      p.total_ms >= l.total_ms,
      "startup: the parent's total includes the leaf's (a waterfall, not two flat entries)"
    )
    ok(
      p.self_ms < p.total_ms,
      "startup: the parent's self time excludes the leaf it required — the whole point"
    )
    eq(l.depth > p.depth, true, "startup: the leaf's recorded depth is below the parent's")
  end

  -- A cache hit is not a load: requiring an already-loaded module must not
  -- add an entry, or the report drowns in no-ops.
  do
    startup.reset()
    startup.start()
    -- ra_spec_parent is still in package.loaded from the block above.
    require("ra_spec_parent")
    require("ra_spec_parent")
    startup.stop()

    eq(
      #startup.report().modules,
      0,
      "startup: a package.loaded cache hit is never recorded as a load"
    )
  end

  -- A module that raises during load: recorded, flagged, the error still
  -- propagates verbatim, and — the real risk — the internal stack stays
  -- balanced, so the *next* module's self time is not attributed to a
  -- parent that already finished.
  do
    startup.reset()
    package.loaded.ra_spec_boom = nil
    package.loaded.ra_spec_leaf = nil

    startup.start()
    local ok_call, err = pcall(require, "ra_spec_boom")
    eq(ok_call, false, "startup: a raising module's error still propagates")
    ok(
      tostring(err):find("module raised during load", 1, true) ~= nil,
      "startup: ... verbatim, not swallowed or rewrapped"
    )

    -- If the stack were left unbalanced by the raise above, this load would
    -- have its cost subtracted from the dead entry instead of standing on
    -- its own.
    require("ra_spec_leaf")
    startup.stop()

    local by_name = {}
    for _, e in ipairs(startup.report().modules) do
      by_name[e.modname] = e
    end
    eq(by_name.ra_spec_boom.errored, true, "startup: the raising module is flagged as errored")
    ok(by_name.ra_spec_leaf ~= nil, "startup: a module loaded after a raise is still recorded")
    ok(
      by_name.ra_spec_leaf.self_ms > 0,
      "startup: ... with its own real self time — the stack stayed balanced through the raise"
    )
  end

  -- Grouping by module root (a plugin's own Lua namespace) and rendering.
  do
    startup.reset()
    package.loaded.ra_spec_leaf = nil
    package.loaded.ra_spec_parent = nil

    startup.start()
    require("ra_spec_parent")
    startup.stop()

    local report = startup.report()
    ok(report.total_ms > 0, "startup.report: a real total")
    eq(#report.roots, 2, "startup.report: two distinct module roots (both top-level names)")

    local lines = startup.lines(report)
    ok(#lines > 0, "startup.lines: produces output")
    ok(
      table.concat(lines, "\n"):find("ra_spec_parent", 1, true) ~= nil,
      "startup.lines: names the modules it recorded"
    )

    local md = startup.markdown(report)
    ok(#md > 0, "startup.markdown: produces output")
    ok(md[1]:find("^# ") ~= nil, "startup.markdown: starts with a real heading")

    -- top/sort are honored.
    eq(#startup.report({ top = 1 }).modules, 1, "startup.report: top = 1 keeps exactly one entry")
    local by_name_sorted = startup.report({ sort = "name" }).modules
    ok(
      by_name_sorted[1].modname < by_name_sorted[2].modname,
      "startup.report: sort = 'name' orders alphabetically"
    )
  end

  package.path = saved_path
  package.loaded.ra_spec_leaf = nil
  package.loaded.ra_spec_parent = nil
  package.loaded.ra_spec_boom = nil
  startup.reset()
end
