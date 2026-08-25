-- TESTS/cost_vs_use_spec.lua — runtime-analysis.telemetry.cost_vs_use
-- (docs/ROADMAP.md §7.2)
--
-- Pure logic, no I/O: resolved_modules() + total_calls + a startup report
-- in, a joined entry (or an honest "unknown, and why") out. Fabricated
-- inputs throughout — this module never talks to a live telemetry instance
-- or `startup.lua` itself, by design (see the module doc-comment).

return function(H)
  local eq, ok = H.eq, H.ok
  local cost_vs_use = require("runtime-analysis.telemetry.cost_vs_use")

  ---@param roots { root: string, self_ms: number }[]
  local function startup_report(roots)
    return { running = false, total_ms = 0, modules = {}, roots = roots }
  end

  -- The common case: a namespace whose resolved modules match real
  -- startup entries.
  do
    local entry = cost_vs_use.build(
      "markdown.nvim",
      { ["buffer.render"] = "markdown.buffer", ["config.setup"] = "markdown.config" },
      1000,
      startup_report({ { root = "markdown", self_ms = 12.5 }, { root = "lib", self_ms = 3.0 } })
    )
    eq(entry.namespace, "markdown.nvim", "build: namespace passed through")
    eq(entry.startup_ms, 12.5, "build: startup_ms is the matched root's own self time")
    eq(
      #entry.matched_roots,
      1,
      "build: exactly one root matched (both keys resolve to the same root)"
    )
    eq(
      entry.matched_roots[1],
      "markdown",
      "build: the matched root is the real module root, not the namespace"
    )
    eq(
      entry.resolved_root_count,
      1,
      "build: one distinct real module root known for this namespace"
    )
    eq(entry.calls_per_ms, 1000 / 12.5, "build: calls_per_ms is total_calls / startup_ms")
    eq(entry.reason, nil, "build: no reason needed when startup_ms is known")
  end

  -- A namespace with no resolvable module at all — wrap()-only, no
  -- wrap_loaded()/module_id. startup_ms must be nil, not 0: "unknown" and
  -- "genuinely free" are different claims.
  do
    local entry = cost_vs_use.build("plain-wrap-only", {}, 500, startup_report({}))
    eq(entry.startup_ms, nil, "build: no resolved modules at all — startup_ms is nil, not 0")
    eq(entry.resolved_root_count, 0, "build: zero resolved roots")
    eq(entry.calls_per_ms, nil, "build: calls_per_ms is also nil when startup_ms is")
    ok(entry.reason ~= nil, "build: a reason is given for the unknown cost")
    ok(entry.reason:find("wrap_loaded", 1, true) ~= nil, "build: the reason names the actual cause")
  end

  -- A namespace WITH a resolved module root, but that root never shows up
  -- in the startup report at all (autostart() wasn't running, or it
  -- loaded before autostart started) — a different reason, still nil,
  -- never a silent 0.
  do
    local entry = cost_vs_use.build(
      "orphan.nvim",
      { f = "orphan.core" },
      42,
      startup_report({ { root = "unrelated", self_ms = 5 } })
    )
    eq(
      entry.startup_ms,
      nil,
      "build: a resolved root with no matching startup entry is still unknown"
    )
    eq(entry.resolved_root_count, 1, "build: the module root itself IS known")
    ok(
      entry.reason:find("none appear", 1, true) ~= nil,
      "build: the reason distinguishes this from 'no module known at all'"
    )
  end

  -- Multiple resolved modules under different roots (a namespace whose
  -- wrap_loaded() spans more than one real top-level module) sum correctly.
  do
    local entry = cost_vs_use.build(
      "multi",
      { a = "root_one.x", b = "root_two.y" },
      100,
      startup_report({ { root = "root_one", self_ms = 4 }, { root = "root_two", self_ms = 6 } })
    )
    eq(entry.startup_ms, 10, "build: multiple matched roots sum their self_ms")
    eq(#entry.matched_roots, 2, "build: both roots recorded as matched")
  end

  -- build_all: sorting puts the worst (lowest calls/ms — expensive AND
  -- underused) first, unknowns last regardless of their own call count,
  -- and never crashes on an empty instance list.
  do
    eq(
      #cost_vs_use.build_all({}, startup_report({})),
      0,
      "build_all: empty instance list — empty result"
    )

    local report = startup_report({
      { root = "cheap_heavy", self_ms = 1 },
      { root = "expensive_light", self_ms = 100 },
    })
    local entries = cost_vs_use.build_all({
      {
        namespace = "expensive_light.nvim",
        resolved_modules = { f = "expensive_light.x" },
        total_calls = 10,
      },
      {
        namespace = "cheap_heavy.nvim",
        resolved_modules = { f = "cheap_heavy.x" },
        total_calls = 10000,
      },
      { namespace = "unknown.nvim", resolved_modules = {}, total_calls = 5 },
    }, report)

    eq(#entries, 3, "build_all: every instance produces exactly one entry")
    eq(
      entries[1].namespace,
      "expensive_light.nvim",
      "build_all: worst calls/ms (expensive, underused) sorts first"
    )
    eq(
      entries[2].namespace,
      "cheap_heavy.nvim",
      "build_all: cheap-and-heavily-used sorts after the worst offender"
    )
    eq(entries[3].namespace, "unknown.nvim", "build_all: unknown-cost entries always sort last")
  end

  -- Rendering doesn't error, on both a real entry and an unknown one, and
  -- surfaces the reason text for the reader.
  do
    local report = startup_report({ { root = "root", self_ms = 2 } })
    local entries = cost_vs_use.build_all({
      { namespace = "known.nvim", resolved_modules = { f = "root.x" }, total_calls = 40 },
      { namespace = "unknown.nvim", resolved_modules = {}, total_calls = 5 },
    }, report)

    local lines = cost_vs_use.lines(entries)
    ok(#lines > 0, "lines: produces output")
    local joined = table.concat(lines, "\n")
    ok(joined:find("known.nvim", 1, true) ~= nil, "lines: names the known namespace")
    ok(joined:find("unknown.nvim", 1, true) ~= nil, "lines: names the unknown namespace")
    ok(joined:find("unknown", 1, true) ~= nil, "lines: marks the unknown one as such")

    local md = cost_vs_use.markdown(entries)
    ok(#md > 0, "markdown: produces output")
    ok(md[1]:find("^# ", 1, false) ~= nil, "markdown: starts with a real heading")
    ok(
      table.concat(md, "\n"):find("Unknown startup cost", 1, true) ~= nil,
      "markdown: a dedicated section explains any unknown-cost entries"
    )

    ok(#cost_vs_use.lines({}) > 0, "lines: an empty entry list still produces output, not an error")
    ok(
      #cost_vs_use.markdown({}) > 0,
      "markdown: an empty entry list still produces output, not an error"
    )
  end
end
