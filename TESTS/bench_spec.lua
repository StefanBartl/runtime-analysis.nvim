-- TESTS/bench_spec.lua — runtime-analysis.bench (docs/ROADMAP.md §3.6)

return function(H)
  local eq, ok = H.eq, H.ok
  local bench = require("runtime-analysis.bench")

  -- A real comparison: one candidate does measurably more work than the
  -- other, so the ranking has a real, checkable answer, not just "it ran".
  --
  -- The inner loop is 20,000 rather than a few hundred, and that number was
  -- measured rather than picked. At 200 the slow/fast ratio came out
  -- anywhere between 2.5x and 6.3x across repeated runs on an *idle*
  -- machine — the run-to-run noise was as large as the signal it is meant
  -- to prove. On a shared CI runner one scheduler preemption during the
  -- `fast` pass is then enough to invert the ranking, which is exactly how
  -- this spec failed intermittently on `main`: green and red runs
  -- alternating with no relevant change between them. At 20,000 the same
  -- measurement gives 336x-529x — two orders of magnitude clear of the
  -- question being asked, for a few milliseconds of extra work.
  do
    local fast_calls, slow_calls = 0, 0
    local function fast()
      fast_calls = fast_calls + 1
    end
    local function slow()
      slow_calls = slow_calls + 1
      local s = 0
      for i = 1, 20000 do
        s = s + i
      end
      return s
    end

    local result, err = bench.compare({
      { name = "fast", fn = fast },
      { name = "slow", fn = slow },
    }, { iterations = 500, warmup = 10 })

    ok(result ~= nil, "compare: a real comparison succeeds: " .. tostring(err))
    eq(result.fastest, "fast", "compare: the cheaper function is reported fastest")
    eq(#result.rows, 2, "compare: one row per candidate")
    eq(result.rows[1].name, "fast", "compare: rows are sorted fastest first")
    eq(result.rows[1].vs_fastest, 1, "compare: the fastest row's own vs_fastest is exactly 1")
    ok(result.rows[2].vs_fastest > 1, "compare: the slower row's vs_fastest is > 1")
    eq(result.rows[1].calls, 500, "compare: calls matches the requested iteration count")

    -- warmup (10) + timed (500) calls happened for each -- proves warmup
    -- is real work, not a no-op the option silently ignores.
    eq(fast_calls, 510, "compare: warmup + iterations both actually ran, for the fast candidate")
    eq(slow_calls, 510, "compare: warmup + iterations both actually ran, for the slow candidate")
  end

  -- args: every candidate is called with the same fixed arguments.
  do
    local seen_a, seen_b
    local result = bench.compare({
      {
        name = "capture",
        fn = function(a, b)
          seen_a, seen_b = a, b
        end,
      },
    }, { iterations = 5, warmup = 0, args = { 7, "x" } })
    ok(result ~= nil, "compare: single-candidate call succeeds")
    eq(seen_a, 7, "compare: args[1] reached the candidate")
    eq(seen_b, "x", "compare: args[2] reached the candidate")
  end

  -- A single candidate is a valid (if trivial) call -- its own baseline,
  -- vs_fastest = 1 for the only row.
  do
    local result = bench.compare({
      { name = "solo", fn = function() end },
    }, { iterations = 10 })
    eq(#result.rows, 1, "compare: a single candidate produces one row")
    eq(result.fastest, "solo", "compare: the only candidate is trivially 'fastest'")
    eq(result.rows[1].vs_fastest, 1, "compare: vs_fastest is 1 with nothing to compare against")
  end

  -- Defaults: iterations=1000, warmup=min(100, iterations).
  do
    local calls = 0
    local function counted()
      calls = calls + 1
    end
    local result = bench.compare({ { name = "x", fn = counted } })
    ok(result ~= nil, "compare: defaults produce a real result")
    eq(result.rows[1].calls, 1000, "compare: default iterations is 1000")
    eq(calls, 1100, "compare: default warmup (100) + default iterations (1000) both ran")
  end

  -- Bad input: no error, a clear reason instead.
  do
    local r1, e1 = bench.compare({})
    eq(r1, nil, "compare: empty candidates -> nil result")
    ok(e1:find("non%-empty", 1) ~= nil, "compare: ... with a reason naming the problem")

    local r2, e2 = bench.compare({ { name = "", fn = function() end } })
    eq(r2, nil, "compare: an empty name -> nil result")
    ok(e2 ~= nil, "compare: ... with a reason")

    local r3, e3 = bench.compare({ { name = "a" } })
    eq(r3, nil, "compare: missing fn -> nil result")
    ok(e3:find("no function", 1, true) ~= nil, "compare: ... with a reason naming which candidate")

    local r4, e4 = bench.compare({
      { name = "dup", fn = function() end },
      { name = "dup", fn = function() end },
    })
    eq(r4, nil, "compare: duplicate names -> nil result")
    ok(e4:find("duplicate", 1, true) ~= nil, "compare: ... with a reason")

    eq(bench.compare(nil), nil, "compare: nil candidates does not error")
    eq(bench.compare("not a table"), nil, "compare: a non-table does not error")
  end

  -- M.lines: a real, readable rendering, not just "doesn't error". Both
  -- candidates are equally trivial (no-ops) on purpose, so their relative
  -- order in the output is measurement noise, not asserted here -- only
  -- that both candidates' own rows are present, somewhere.
  do
    local result = bench.compare({
      { name = "one", fn = function() end },
      { name = "two", fn = function() end },
    }, { iterations = 50 })
    local lines = bench.lines(result)
    eq(#lines, 3, "lines: one header row plus one row per candidate")
    ok(lines[1]:find("Name", 1, true) ~= nil, "lines: header names the columns")
    local rendered = table.concat(lines, "\n")
    ok(rendered:find("one", 1, true) ~= nil, "lines: candidate 'one' has its own row")
    ok(rendered:find("two", 1, true) ~= nil, "lines: candidate 'two' has its own row")
  end
end
