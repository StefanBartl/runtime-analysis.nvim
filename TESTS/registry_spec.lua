-- TESTS/registry_spec.lua — runtime-analysis.telemetry.registry
--
-- The shared wrap layer on its own, without a telemetry instance around it:
-- a fake instance records what the wrapper dispatches.

return function(H)
  local registry = require("runtime-analysis.telemetry.registry")

  local function fake_inst(namespace)
    local inst = { namespace = namespace, calls = 0 }
    function inst._record()
      inst.calls = inst.calls + 1
    end
    return inst
  end

  -- -------------------------------------------------------------------------
  -- a local re-wrap of an already wrapped field must not be adopted as the
  -- original: wrapper -> replacement -> wrapper -> ... is an endless tail call
  -- -------------------------------------------------------------------------
  do
    local original_calls = 0
    local M = {}
    function M.f(x)
      original_calls = original_calls + 1
      return x, nil, "third"
    end

    local inst = fake_inst("spec.registry.rewrap")
    H.ok(registry.attach(M, "f", "M.f", inst, {}), "first attach installs the wrapper")

    -- The pattern of config/ui_open.lua: wrap whatever is there right now,
    -- which is our wrapper.
    local replacement_calls = 0
    local orig = M.f
    M.f = function(...)
      replacement_calls = replacement_calls + 1
      -- Bail out instead of hanging the test run when the loop exists.
      if replacement_calls > 50 then
        error("endless wrapper <-> replacement loop", 0)
      end
      return orig(...)
    end
    local replacement = M.f

    H.ok(registry.attach(M, "f", "M.f", inst, {}), "second attach after the re-wrap")

    local ok, a, b, c = pcall(M.f, 7)
    H.ok(ok, "calling the field after the second attach terminates: " .. tostring(a))
    H.eq(original_calls, 1, "the original runs exactly once")
    H.eq(replacement_calls, 1, "the replacement runs exactly once")
    H.eq(inst.calls, 1, "the call is counted once, through the old wrapper")
    H.eq(a, 7, "first return value passes through")
    H.eq(b, nil, "a nil in the middle passes through")
    H.eq(c, "third", "the value after the nil passes through")
    H.eq(M.f, replacement, "the replacement stays in the field")

    registry.detach(M, "f", inst)
    H.eq(type(M.f), "function", "detach leaves a function behind")
    original_calls, replacement_calls = 0, 0
    local ok2, r = pcall(M.f, 9)
    H.ok(ok2, "the field is still callable after detach: " .. tostring(r))
    H.eq(r, 9, "...and returns the original's value")
    H.eq(original_calls, 1, "...after running the original once")
  end

  -- -------------------------------------------------------------------------
  -- a genuine replacement (no reference to the wrapper) is still adopted
  -- -------------------------------------------------------------------------
  do
    local M = {}
    function M.f()
      return "old"
    end
    local inst = fake_inst("spec.registry.adopt")
    registry.attach(M, "f", "M.f", inst, {})

    function M.f()
      return "new"
    end
    registry.attach(M, "f", "M.f", inst, {})

    H.ok(registry.is_wrapped(M, "f"), "the wrapper is re-installed over the replacement")
    H.eq(M.f(), "new", "callers reach the replacement")
    H.eq(inst.calls, 1, "...and the call is counted")

    registry.detach(M, "f", inst)
    H.eq(M.f(), "new", "detach restores the replacement, not the first original")
  end
end
