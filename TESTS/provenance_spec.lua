-- TESTS/provenance_spec.lua — runtime-analysis.provenance
-- (docs/ROADMAP.md §5.2)
--
-- Real globals and real telemetry instances, not stubs: provenance's whole
-- point is inspecting what is *actually* installed right now, so a fake
-- container would only prove the fake worked.

return function(H)
  local eq, ok = H.eq, H.ok
  local provenance = require("runtime-analysis.provenance")
  local telemetry = require("runtime-analysis.telemetry")

  local seq = 0
  local function ns(name)
    seq = seq + 1
    return ("spec.provenance.%s.%d"):format(name, seq)
  end

  -- No dot at all: a clear error, not a confusing resolution attempt.
  do
    local info, err = provenance.inspect("bareword")
    eq(info, nil, "inspect: a path with no '.' fails")
    ok(err and err:find("'.'", 1, true) ~= nil, "inspect: the error names exactly what's missing")
  end

  -- A real global-table path to a real function, currently unwrapped by
  -- anything this plugin knows about.
  do
    local info, err = provenance.inspect("vim.trim")
    eq(err, nil, "inspect: vim.trim resolves with no error")
    assert(info, "inspect: vim.trim resolves")
    eq(info.container_kind, "global", "inspect: vim.trim resolves via the global-table walk")
    eq(info.field, "trim", "inspect: the field name is the last path segment")
    eq(info.telemetry.wrapped, false, "inspect: vim.trim is not wrapped by this plugin's telemetry")
    eq(#info.telemetry.namespaces, 0, "inspect: no namespaces when not wrapped")
  end

  -- An unresolvable container: a real error naming what failed, not a
  -- crash or a table full of nils.
  do
    local info, err = provenance.inspect("this.does.not.exist.at.all")
    eq(info, nil, "inspect: an unresolvable container path fails")
    ok(err ~= nil, "inspect: ... with a real error")
  end

  -- A container that resolves, but the field itself does not exist.
  do
    local info, err = provenance.inspect("vim.this_field_does_not_exist")
    eq(info, nil, "inspect: a missing field on a real container fails")
    ok(
      err and err:find("this_field_does_not_exist", 1, true) ~= nil,
      "inspect: the error names the field"
    )
  end

  -- The target resolves, but is not a function at all.
  do
    local info, err = provenance.inspect("vim.log.levels")
    eq(info, nil, "inspect: a non-function target fails")
    ok(err and err:find("table", 1, true) ~= nil, "inspect: the error names the actual type")
  end

  -- The real point: a function this plugin's own telemetry actually wraps
  -- right now is reported precisely, by namespace — not best-effort at all.
  do
    local mod = {
      f = function() end,
    }
    local t = telemetry.new({ namespace = ns("wrapped"), persist = false })
    t.wrap(mod)
    t.start()

    -- Reach the wrapped function through a real global path, the same way
    -- a reader would for `vim.notify`: stash it somewhere globally
    -- reachable, since `inspect` only ever resolves dotted paths, never a
    -- direct table reference.
    _G.__ra_provenance_spec_container = mod
    local info = provenance.inspect("__ra_provenance_spec_container.f")
    assert(info, "inspect: the wrapped function resolves")
    eq(info.telemetry.wrapped, true, "inspect: a live-wrapped function is reported as wrapped")
    eq(#info.telemetry.namespaces, 1, "inspect: exactly one subscriber namespace")
    eq(
      info.telemetry.namespaces[1],
      t.namespace,
      "inspect: the namespace is the real one, not a guess"
    )
    ok(info.source ~= nil, "inspect: a source location is reported for the installed wrapper")

    t.stop()
    t.unwrap()
    _G.__ra_provenance_spec_container = nil

    -- After unwrap, the same path is no longer reported as wrapped — this
    -- plugin's own registry state is read live, not cached from the first
    -- inspect() call.
    _G.__ra_provenance_spec_container2 = mod
    local info2 = provenance.inspect("__ra_provenance_spec_container2.f")
    assert(info2, "inspect: still resolves after unwrap")
    eq(info2.telemetry.wrapped, false, "inspect: no longer wrapped after t.unwrap()")
    _G.__ra_provenance_spec_container2 = nil
  end

  -- Two telemetry instances wrapping the identical function: both
  -- namespaces are named, not just one.
  do
    local mod = {
      f = function() end,
    }
    local t1 = telemetry.new({ namespace = ns("multi_a"), persist = false })
    local t2 = telemetry.new({ namespace = ns("multi_b"), persist = false })
    t1.wrap(mod)
    t2.wrap(mod)
    t1.start()
    t2.start()

    _G.__ra_provenance_spec_multi = mod
    local info = provenance.inspect("__ra_provenance_spec_multi.f")
    assert(info, "inspect: resolves with two subscribers")
    eq(#info.telemetry.namespaces, 2, "inspect: both subscriber namespaces are reported")
    ok(
      vim.tbl_contains(info.telemetry.namespaces, t1.namespace)
        and vim.tbl_contains(info.telemetry.namespaces, t2.namespace),
      "inspect: both real namespaces are present, not one dropped"
    )

    t1.stop()
    t2.stop()
    t1.unwrap()
    t2.unwrap()
    _G.__ra_provenance_spec_multi = nil
  end

  -- A module-path resolution (require(), not the global table) — the
  -- lib.nvim-style case, not the vim.* one.
  do
    local info, err = provenance.inspect("runtime-analysis.parse.split")
    eq(err, nil, "inspect: a real require()-able module field resolves")
    assert(info, "inspect: resolves via require()")
    eq(info.container_kind, "module", "inspect: resolved via require(), not the global table")
    eq(info.field, "split", "inspect: field name correct for a module path")
  end

  -- Rendering: produces readable output for both the wrapped and
  -- best-effort-unwrapped cases, without erroring.
  do
    local info = assert(provenance.inspect("vim.trim"))
    local lines = provenance.lines(info)
    ok(#lines > 0, "lines: produces output")
    local joined = table.concat(lines, "\n")
    ok(joined:find("vim.trim", 1, true) ~= nil, "lines: names the inspected path")
    ok(joined:find("not wrapped", 1, true) ~= nil, "lines: states plainly when not wrapped")
    ok(
      joined:find("best%-effort", 1, false) ~= nil,
      "lines: the best-effort caveat is shown when unwrapped"
    )
  end

  -- ---------------------------------------------------------------------
  -- `lib.nvim.system.proc_trace` — the second wrapper this can name exactly.
  --
  -- **This is what `docs/IDEAS.md` §4.1 asked for, reached without what it
  -- proposed.** That entry wanted a shared wrapper-registry convention in
  -- `lib.nvim` so provenance could answer for every instance of this
  -- technique. It was decided against — one consumer, and the case that
  -- would justify it (a third-party monkey-patch) is exactly the one a
  -- convention cannot reach. `proc_trace` already publishes `is_active()`,
  -- so the two wrappers this ecosystem controls are answerable with no new
  -- convention at all.
  --
  -- Driven through a real `start()`/`stop()` rather than a stubbed flag: the
  -- claim is about what is actually installed on `vim.fn.system` right now,
  -- and a stub would assert the branch instead of the fact.
  -- ---------------------------------------------------------------------
  do
    local ok_trace, trace = pcall(require, "lib.nvim.system.proc_trace")
    if not ok_trace or type(trace.start) ~= "function" then
      ok(true, "provenance: no proc_trace in this lib.nvim — skipping")
    else
      local function reported()
        local info = assert(provenance.inspect("vim.fn.system"))
        return info.proc_trace, table.concat(provenance.lines(info), "\n")
      end

      local before, before_lines = reported()
      eq(before, false, "provenance: not claimed before proc_trace runs")
      ok(
        before_lines:find("best%-effort", 1, false) ~= nil,
        "provenance: ...and the caveat is shown, since nothing answered exactly"
      )

      trace.start({ threshold_ms = 5000 })
      local during, during_lines = reported()
      trace.stop()

      eq(during, true, "provenance: named exactly while proc_trace is active")
      ok(during_lines:find("proc_trace", 1, true) ~= nil, "provenance: ...and the report says so")
      -- The condition that had to widen when a second exact source arrived.
      -- Left as it was, a reader shown "wrapped by proc_trace" would have
      -- been told in the next line that nothing here knows about wraps other
      -- than this plugin's — contradicting the line above it.
      eq(
        during_lines:find("best%-effort", 1, false),
        nil,
        "provenance: no best-effort caveat once something answered exactly"
      )

      local after = reported()
      eq(after, false, "provenance: released again after stop()")

      -- A path proc_trace never touches must never be claimed, active or not.
      trace.start({ threshold_ms = 5000 })
      local other = assert(provenance.inspect("vim.trim"))
      trace.stop()
      eq(other.proc_trace, false, "provenance: only the four paths it actually wraps")
    end
  end

  -- ------------------------------------------------ `:RA provenance` completion
  --
  -- The argtype registered in `bindings/usrcmds.lua`. Two things matter and
  -- neither is visible from the candidate list alone: that it splits the
  -- dotted path the way `inspect` does, and that Tab never loads a module.

  require("runtime-analysis").setup({})

  local function candidates(lead)
    return vim.fn.getcompletion("RA provenance " .. lead, "cmdline")
  end

  local loaded_before = vim.tbl_count(package.loaded)

  local top = candidates("")
  ok(#top > 0, "provenance completion: offers containers with an empty lead")
  ok(vim.tbl_contains(top, "vim"), "provenance completion: `vim` is offered as a container")

  local fields = candidates("vim.not")
  ok(
    vim.tbl_contains(fields, "vim.notify"),
    "provenance completion: completes a function field to its full dotted path"
  )
  for _, c in ipairs(fields) do
    eq(c:sub(1, 7), "vim.not", "provenance completion: every candidate keeps the typed prefix")
  end

  -- A table field is offered too -- it is the way down to a function.
  ok(
    vim.tbl_contains(candidates("vim.f"), "vim.fn"),
    "provenance completion: table fields are offered as the path onward"
  )

  eq(
    #candidates("definitely_not_a_module.field"),
    0,
    "provenance completion: an unresolvable container yields nothing, not a guess"
  )

  -- The one that would be a real bug rather than a cosmetic one: completing
  -- must never `require`, or pressing Tab would run arbitrary module top-level
  -- code (autocmd registration included) as a side effect of a keypress.
  candidates("lib.")
  candidates("runtime-analysis.")
  candidates("vim.")
  eq(
    vim.tbl_count(package.loaded),
    loaded_before,
    "provenance completion: a completion sweep loads no module"
  )
end
