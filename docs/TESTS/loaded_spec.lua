-- docs/TESTS/loaded_spec.lua — runtime-analysis.loaded (docs/ROADMAP.md §5.3)

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
end
