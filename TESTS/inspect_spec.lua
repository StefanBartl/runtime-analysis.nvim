-- TESTS/inspect_spec.lua — runtime-analysis.inspect (`:RA inspect <module>`)
--
-- Real `package.loaded` fixtures, not stubs: the whole point of this module
-- is walking what is *actually* on a live table right now, so a fake
-- `package.loaded` entry is exactly the right level of realism -- it is
-- real from `inspect.lua`'s own point of view, which never distinguishes
-- "a plugin's own module" from "a spec's own fixture module".

return function(H)
  local eq, ok = H.eq, H.ok
  local inspect = require("runtime-analysis.inspect")

  -- Not loaded at all: a clear error naming exactly that, not a crash.
  do
    local report, err = inspect.inspect("__inspect_spec_never_required")
    eq(report, nil, "inspect: an unloaded module fails")
    ok(err and err:find("not loaded", 1, true) ~= nil, "inspect: the error says so plainly")
  end

  -- Loaded, but not a table at all -- the honest "nothing to walk" case.
  do
    package.loaded["__inspect_spec_fn_module"] = function() end
    local report, err = inspect.inspect("__inspect_spec_fn_module")
    eq(report, nil, "inspect: a non-table module fails")
    ok(err and err:find("function", 1, true) ~= nil, "inspect: the error names the real type")
    package.loaded["__inspect_spec_fn_module"] = nil
  end

  -- Empty string / nil module_id: handled without error, not a crash.
  do
    local report1, err1 = inspect.inspect("")
    eq(report1, nil, "inspect: an empty module_id fails")
    ok(err1 ~= nil, "inspect: ... with a real error")

    local ok2 = pcall(inspect.inspect, nil)
    ok(ok2, "inspect: a nil module_id does not error the caller")
  end

  -- Functions: upvalue count and source location, both real.
  do
    local upval = "captured"
    local mod = {
      with_upvalue = function()
        return upval
      end,
      no_upvalue = function() end,
    }
    package.loaded["__inspect_spec_functions"] = mod

    local report = assert(inspect.inspect("__inspect_spec_functions"))
    local by_key = {}
    for _, e in ipairs(report.entries) do
      by_key[e.key] = e
    end

    eq(by_key.with_upvalue.kind, "function", "inspect: a function field is kind=function")
    ok(by_key.with_upvalue.nups >= 1, "inspect: a real captured upvalue is counted")
    eq(by_key.no_upvalue.nups, 0, "inspect: no upvalues counted as zero, not nil")
    ok(by_key.with_upvalue.source ~= nil, "inspect: a real Lua function has a source location")
    ok(
      by_key.with_upvalue.source.short_src:find("inspect_spec", 1, true) ~= nil,
      "inspect: the source location names this very spec file"
    )

    package.loaded["__inspect_spec_functions"] = nil
  end

  -- Nested tables: real recursion, field counts, and scalar values --
  -- string/number/boolean rendered, nothing else guessed at.
  do
    local mod = {
      nested = {
        a_string = "hello",
        a_number = 42,
        a_bool = true,
      },
    }
    package.loaded["__inspect_spec_nested"] = mod

    local report = assert(inspect.inspect("__inspect_spec_nested"))
    local nested_entry = report.entries[1]
    eq(nested_entry.key, "nested", "inspect: the nested table's own key")
    eq(nested_entry.kind, "table", "inspect: a table field is kind=table")
    eq(#nested_entry.entries, 3, "inspect: all three real fields found")

    local by_key = {}
    for _, e in ipairs(nested_entry.entries) do
      by_key[e.key] = e
    end
    eq(by_key.a_string.kind, "other", "inspect: a string is kind=other")
    eq(by_key.a_string.value_type, "string", "inspect: value_type is the real Lua type")
    eq(by_key.a_string.value_repr, '"hello"', "inspect: a short string is rendered in full")
    eq(by_key.a_number.value_repr, "42", "inspect: a number's literal value")
    eq(by_key.a_bool.value_repr, "true", "inspect: a boolean's literal value")

    package.loaded["__inspect_spec_nested"] = nil
  end

  -- A long string is truncated, not dumped in full -- readability, not
  -- correctness, the same "cosmetic cap" reasoning the depth limit itself
  -- gets in the module's own doc-comment.
  do
    local mod = { long = ("x"):rep(200) }
    package.loaded["__inspect_spec_long_string"] = mod
    local report = assert(inspect.inspect("__inspect_spec_long_string"))
    ok(#report.entries[1].value_repr < 80, "inspect: a long string is truncated")
    package.loaded["__inspect_spec_long_string"] = nil
  end

  -- Cycle safety: a table that contains itself must not hang or overflow
  -- the stack -- the identity-keyed ancestor-chain `seen` set this module's
  -- own doc-comment names as the correctness mechanism.
  do
    local mod = { child = {} }
    mod.child.parent = mod -- a real cycle, not a simulated one
    package.loaded["__inspect_spec_cycle"] = mod

    local report = assert(inspect.inspect("__inspect_spec_cycle"))
    local child_entry = report.entries[1]
    eq(child_entry.key, "child", "inspect: the cyclic child is still reached once")
    local parent_entry = child_entry.entries[1]
    eq(parent_entry.key, "parent", "inspect: the back-reference is still reported")
    ok(parent_entry.cyclic, "inspect: ... and flagged as a cycle rather than recursed into")
    eq(parent_entry.entries, nil, "inspect: a cyclic node carries no further entries")

    package.loaded["__inspect_spec_cycle"] = nil
  end

  -- A table shared between two sibling branches (not nested in itself) is
  -- not a cycle -- the `seen` set only tracks the current ancestor chain,
  -- cleared on return, so both branches walk it in full.
  do
    local shared = { value = 1 }
    local mod = { a = shared, b = shared }
    package.loaded["__inspect_spec_shared"] = mod

    local report = assert(inspect.inspect("__inspect_spec_shared"))
    local by_key = {}
    for _, e in ipairs(report.entries) do
      by_key[e.key] = e
    end
    ok(not by_key.a.cyclic, "inspect: a shared (non-cyclic) table in branch a is walked in full")
    ok(not by_key.b.cyclic, "inspect: ... and again in branch b, not falsely flagged as a cycle")
    eq(#by_key.a.entries, 1, "inspect: branch a sees the real field")
    eq(#by_key.b.entries, 1, "inspect: branch b sees the real field too")

    package.loaded["__inspect_spec_shared"] = nil
  end

  -- Depth limit: a real cosmetic cap, not correctness -- deep but acyclic
  -- nesting past `max_depth` is reported as truncated rather than walked
  -- forever or erroring.
  do
    local mod = { l1 = { l2 = { l3 = { l4 = { deep = true } } } } }
    package.loaded["__inspect_spec_deep"] = mod

    local report = assert(inspect.inspect("__inspect_spec_deep", { max_depth = 2 }))
    local l1 = report.entries[1]
    eq(l1.key, "l1", "inspect: depth 1 (the module's own field) is always reached")
    ok(not l1.truncated, "inspect: depth 1 is within a max_depth of 2")
    local l2 = l1.entries[1]
    eq(l2.key, "l2", "inspect: depth 2 is still within max_depth")
    ok(l2.truncated, "inspect: depth 2's own children are past max_depth=2, so truncated")
    eq(l2.entries, nil, "inspect: a truncated node carries no entries")
    ok(l2.field_count ~= nil and l2.field_count >= 1, "inspect: the field count is still reported")

    package.loaded["__inspect_spec_deep"] = nil
  end

  -- __index as a table: a direct key also present on __index is reported
  -- as shadowing it. A key that exists only via __index (not directly on
  -- the table itself) is not walked at all -- `pairs()` never yields it,
  -- honestly reflecting what `rawget`/direct iteration actually sees.
  do
    local base = { inherited = 1, overridden = "base value" }
    local mod = setmetatable({ overridden = "own value" }, { __index = base })
    package.loaded["__inspect_spec_index_table"] = mod

    local report = assert(inspect.inspect("__inspect_spec_index_table"))
    eq(report.has_metatable, true, "inspect: metatable presence is reported")
    eq(report.index_kind, "table", "inspect: __index kind is identified as a table")
    eq(#report.entries, 1, "inspect: only the direct key is walked, not the inherited one")
    eq(report.entries[1].key, "overridden", "inspect: the direct, shadowing key")
    ok(report.entries[1].shadows_index, "inspect: flagged as shadowing __index's own value")

    package.loaded["__inspect_spec_index_table"] = nil
  end

  -- __index as a function: reported as present, never called -- the
  -- module's own second design question, verified by proving the function
  -- genuinely never ran.
  do
    local called = false
    local mod = setmetatable({ own_field = 1 }, {
      __index = function(_, _key)
        called = true
        return nil
      end,
    })
    package.loaded["__inspect_spec_index_fn"] = mod

    local report = assert(inspect.inspect("__inspect_spec_index_fn"))
    eq(report.index_kind, "function", "inspect: __index kind is identified as a function")
    eq(false, called, "inspect: __index was never invoked to find out")
    -- Nothing can be shadowed against a function __index -- there is
    -- nothing to compare keys against without calling it.
    ok(
      not report.entries[1].shadows_index,
      "inspect: no shadowing claimed against a function __index"
    )

    package.loaded["__inspect_spec_index_fn"] = nil
  end

  -- A real self-test: this module, loaded in this very process, walked by
  -- itself -- the identical "point it at the live session that is doing
  -- the analysis" case `runtime-analysis.loaded`'s own doc-comment names
  -- as the real use case for any of this.
  do
    local report = assert(inspect.inspect("runtime-analysis.inspect"))
    local by_key = {}
    for _, e in ipairs(report.entries) do
      by_key[e.key] = e
    end
    ok(by_key.inspect ~= nil, "inspect: self-inspection finds its own M.inspect")
    eq(by_key.inspect.kind, "function", "inspect: ... correctly as a function")
    ok(by_key.lines ~= nil, "inspect: self-inspection finds its own M.lines too")
  end

  -- Rendering: readable output, no error, for functions/tables/scalars/
  -- shadowing/cycles/truncation all in the same tree.
  do
    local base = { shared_key = "from base" }
    local mod = setmetatable({
      fn = function() end,
      shared_key = "own",
      nested = { x = 1 },
    }, { __index = base })
    mod.nested.back = mod -- a real cycle inside the rendered tree too
    package.loaded["__inspect_spec_render"] = mod

    local report = assert(inspect.inspect("__inspect_spec_render"))
    local lines = inspect.lines(report)
    ok(#lines > 0, "lines: produces output")
    local joined = table.concat(lines, "\n")
    ok(joined:find("__inspect_spec_render", 1, true) ~= nil, "lines: names the inspected module")
    ok(joined:find("fn()", 1, true) ~= nil, "lines: a function entry is rendered with ()")
    ok(joined:find("upvalue", 1, true) ~= nil, "lines: upvalue count is shown")
    ok(joined:find("shadows __index", 1, true) ~= nil, "lines: shadowing is called out")
    ok(joined:find("cycle", 1, true) ~= nil, "lines: a cycle is called out, not silently dropped")

    package.loaded["__inspect_spec_render"] = nil
  end
end
