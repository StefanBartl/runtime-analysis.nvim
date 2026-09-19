-- Test code: when something here comes back nil -- a `pcall(require, ...)`,
-- a fixture read, a uv handle -- this file must crash and name it. The nil
-- guards LuaLS asks for below would hide the very failure it exists to report.
---@diagnostic disable: need-check-nil
-- TESTS/loaded_spec.lua — runtime-analysis.loaded

return function(H)
  local eq, ok = H.eq, H.ok
  local loaded = require("runtime-analysis.loaded")

  -- A module never required at all: nil, not an error and not an empty set
  -- masquerading as "loaded with nothing on it".
  do
    eq(
      loaded.functions("this.module.was.never.required.anywhere"),
      nil,
      "functions: nil for a module never required this session"
    )
    eq(
      loaded.is_loaded("this.module.was.never.required.anywhere"),
      false,
      "is_loaded: false for the same"
    )
  end

  -- A real, already-loaded module (this very plugin) -- exercised against
  -- itself rather than a fixture, so this proves the real package.loaded
  -- read works, not a stand-in for it.
  do
    ok(loaded.is_loaded("runtime-analysis.loaded"), "is_loaded: true for this module itself")
    local fns = loaded.functions("runtime-analysis.loaded")
    ok(fns ~= nil, "functions: a real table for a real loaded module")
    ok(fns["functions"], "functions: sees its own M.functions field")
    ok(fns["is_loaded"], "functions: sees its own M.is_loaded field")
  end

  -- Only function-valued keys, not data fields -- matches the same
  -- distinction telemetry_join.lua's own doc-comment states on the
  -- documentation.nvim side for exactly the same reason (a module map's
  -- own function index is what this has to line up against).
  do
    package.loaded["__loaded_spec_fixture"] = {
      a_function = function() end,
      a_string = "not a function",
      a_table = {},
      [1] = function() end, -- non-string key, must not appear either
    }
    local fns = assert(loaded.functions("__loaded_spec_fixture"))
    eq(fns.a_function, true, "functions: a real function field is included")
    eq(fns.a_string, nil, "functions: a non-function field is excluded")
    eq(
      fns.a_table,
      nil,
      "functions: a nested table is excluded -- it is its own module, not a field"
    )
    local count = 0
    for _ in pairs(fns) do
      count = count + 1
    end
    eq(count, 1, "functions: exactly one key survived -- the non-string key never counted")
    package.loaded["__loaded_spec_fixture"] = nil
  end

  -- Loaded, but genuinely nothing function-shaped on it -- a real, distinct
  -- answer from "not loaded at all", not collapsed into the same nil.
  do
    package.loaded["__loaded_spec_data_only"] = { x = 1, y = 2 }
    local fns = loaded.functions("__loaded_spec_data_only")
    ok(fns ~= nil, "functions: a real (empty) table, not nil, for a loaded data-only module")
    fns = assert(fns)
    local count = 0
    for _ in pairs(fns) do
      count = count + 1
    end
    eq(count, 0, "functions: zero function keys, honestly, not treated as unloaded")
    package.loaded["__loaded_spec_data_only"] = nil
  end

  -- A bogus module_id: no error, same "not loaded" answer.
  do
    eq(loaded.functions(""), nil, "functions: empty string is not a module id")
    -- Deliberately invalid: answering nil rather than raising is the point.
    ---@diagnostic disable-next-line: param-type-mismatch
    eq(loaded.functions(nil), nil, "functions: nil input does not error")
  end

  -- --------------------------------------------- persisted snapshots (§5.4)

  local PREFIX = "__loaded_spec_snap"

  do
    package.loaded[PREFIX] = { top_fn = function() end, top_data = 1 }
    package.loaded[PREFIX .. ".sub"] = { sub_fn = function() end }
    package.loaded[PREFIX .. "_not_a_match"] = { decoy = function() end }

    local name = loaded.snapshot(PREFIX, "spec-name")
    eq(name, "spec-name", "snapshot: returns the (sanitized) name it was given")

    local snap = loaded.load_snapshot(PREFIX, "spec-name")
    ok(snap ~= nil, "load_snapshot: real data comes back")
    eq(snap.prefix, PREFIX, "load_snapshot: records the prefix it was taken under")
    ok(snap.modules[PREFIX] ~= nil, "load_snapshot: the prefix module itself is captured")
    eq(snap.modules[PREFIX].top_fn, true, "load_snapshot: function field captured")
    eq(snap.modules[PREFIX].top_data, nil, "load_snapshot: non-function field excluded")
    ok(
      snap.modules[PREFIX .. ".sub"] ~= nil,
      "load_snapshot: a dotted submodule under prefix is captured"
    )
    eq(
      snap.modules[PREFIX .. "_not_a_match"],
      nil,
      "load_snapshot: a module that merely starts with the prefix string (no dot boundary) is excluded"
    )

    local list = loaded.list_snapshots(PREFIX)
    eq(#list, 1, "list_snapshots: exactly the one saved snapshot")
    eq(list[1].name, "spec-name", "list_snapshots: correct name")

    package.loaded[PREFIX] = nil
    package.loaded[PREFIX .. ".sub"] = nil
    package.loaded[PREFIX .. "_not_a_match"] = nil
  end

  -- Nothing loaded under the prefix at all: no snapshot, no error.
  do
    eq(
      loaded.snapshot("__loaded_spec_nothing_here", "x"),
      nil,
      "snapshot: nil when nothing is loaded under the prefix"
    )
  end

  -- Retention: capping at a small number evicts down to the cap. Which one
  -- specifically gets evicted is not asserted beyond that — `saved_at` is
  -- second-granularity (`mtime.sec`, the same precision
  -- `telemetry/store.lua#M.list_snapshots` already accepts), and three
  -- snapshots saved back-to-back inside one test can land in the same
  -- second, at which point "oldest" is not actually distinguishable.
  do
    local RPREFIX = "__loaded_spec_retention"
    package.loaded[RPREFIX] = { fn = function() end }
    local saved_retention = loaded.SNAPSHOT_RETENTION
    loaded.SNAPSHOT_RETENTION = 2
    loaded.snapshot(RPREFIX, "s1")
    loaded.snapshot(RPREFIX, "s2")
    loaded.snapshot(RPREFIX, "s3")
    local list = loaded.list_snapshots(RPREFIX)
    eq(#list, 2, "snapshot: retention evicts down to SNAPSHOT_RETENTION")
    loaded.SNAPSHOT_RETENTION = saved_retention
    package.loaded[RPREFIX] = nil
  end

  -- Bogus prefix/name: no error, same "nothing to report" shape.
  do
    eq(#loaded.list_snapshots(""), 0, "list_snapshots: empty prefix -> empty list")
    eq(loaded.load_snapshot("", "x"), nil, "load_snapshot: empty prefix -> nil")
    eq(loaded.load_snapshot(PREFIX, ""), nil, "load_snapshot: empty name -> nil")
  end

  -- SEC-33: a persisted snapshot is untrusted input -- hand-edited, written
  -- by an older/newer schema, or from a future format change. Written
  -- directly via lib.nvim.cache.disk, bypassing `M.snapshot`, since the
  -- whole point is data `M.snapshot` itself would never produce.
  do
    local disk = require("lib.nvim.cache.disk")
    local SPREFIX = "__loaded_spec_untrusted"
    local function key(name)
      return "loaded/" .. SPREFIX .. "/snapshots/" .. name
    end

    -- A version this code does not know how to read at all: rejected
    -- wholesale rather than handed back typed as the current shape.
    assert(disk.save(key("bad-version"), { version = 99, prefix = SPREFIX, modules = {} }))
    eq(
      loaded.load_snapshot(SPREFIX, "bad-version"),
      nil,
      "load_snapshot: an unknown schema version is rejected, not trusted as current"
    )

    -- `raw.prefix` disagreeing with the prefix actually asked for: rejected
    -- rather than silently answered under the wrong identity.
    assert(
      disk.save(
        key("wrong-prefix"),
        { version = loaded.VERSION, prefix = "someone.else", modules = {} }
      )
    )
    eq(
      loaded.load_snapshot(SPREFIX, "wrong-prefix"),
      nil,
      "load_snapshot: a snapshot recorded under a different prefix is rejected"
    )

    -- `modules` with the wrong shape at every level: a string instead of a
    -- table, a module entry that isn't a table, a function-key value that
    -- isn't literal `true`. None of this may reach a caller doing
    -- `pairs(snap.modules)` or trusting `snap.modules[id][fn] == true`.
    assert(disk.save(key("bad-modules"), {
      version = loaded.VERSION,
      prefix = SPREFIX,
      modules = "not a table at all",
    }))
    local snap1 = loaded.load_snapshot(SPREFIX, "bad-modules")
    ok(snap1 ~= nil, "load_snapshot: version/prefix still valid -> snapshot comes back")
    eq(type(snap1.modules), "table", "load_snapshot: a non-table modules field degrades to {}")
    local count1 = 0
    for _ in pairs(snap1.modules) do
      count1 = count1 + 1
    end
    eq(count1, 0, "load_snapshot: ...empty, not the raw string")

    assert(disk.save(key("bad-entries"), {
      version = loaded.VERSION,
      prefix = SPREFIX,
      modules = {
        ["a.module"] = "not a table either",
        ["b.module"] = { real_fn = true, fake_fn = 5 },
      },
    }))
    local snap2 = assert(loaded.load_snapshot(SPREFIX, "bad-entries"))
    eq(snap2.modules["a.module"], nil, "load_snapshot: a non-table module entry is dropped")
    ok(snap2.modules["b.module"] ~= nil, "load_snapshot: a well-shaped sibling entry survives")
    eq(snap2.modules["b.module"].real_fn, true, "load_snapshot: a real true-valued key survives")
    eq(
      snap2.modules["b.module"].fake_fn,
      nil,
      "load_snapshot: a non-boolean-true value is dropped, not trusted as a function marker"
    )
    local count2 = 0
    for _ in pairs(snap2.modules["b.module"]) do
      count2 = count2 + 1
    end
    eq(count2, 1, "load_snapshot: exactly the one real true-valued key survived")

    assert(disk.clear(key("bad-version")))
    assert(disk.clear(key("wrong-prefix")))
    assert(disk.clear(key("bad-modules")))
    assert(disk.clear(key("bad-entries")))
  end
end
