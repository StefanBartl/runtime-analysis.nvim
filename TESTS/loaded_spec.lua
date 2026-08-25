-- TESTS/loaded_spec.lua — runtime-analysis.loaded (docs/ROADMAP.md §5.3)

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
    local fns = loaded.functions("__loaded_spec_fixture")
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
end
