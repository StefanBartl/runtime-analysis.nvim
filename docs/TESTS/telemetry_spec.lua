-- docs/TESTS/telemetry_spec.lua — runtime-analysis.telemetry
--
-- Covers the properties the design actually rests on: zero-cost-when-stopped
-- (identity restore), scoping, the shared wrap layer (no double counting, no
-- restore-ordering trap), fingerprinting, merge-on-write persistence, day
-- windows, retention pruning and the lifecycle reminder.

return function(H)
  local telemetry = require("runtime-analysis.telemetry")
  local store = require("runtime-analysis.telemetry.store")
  local fingerprint = require("runtime-analysis.telemetry.fingerprint")
  local reminder = require("runtime-analysis.telemetry.reminder")
  local toggle = require("runtime-analysis.telemetry.toggle")

  local seq = 0
  local function ns(name)
    seq = seq + 1
    return ("spec.%s.%d"):format(name, seq)
  end

  local tmpdir = vim.fn.tempname() .. "-telemetry"
  vim.fn.mkdir(tmpdir, "p")

  -- -------------------------------------------------------------------------
  -- namespace sanitization (cache.disk does none of its own)
  -- -------------------------------------------------------------------------
  H.eq(store.sanitize("lib.nvim"), "lib.nvim", "plain namespace untouched")
  H.eq(
    store.sanitize("../../evil"),
    "_.._evil",
    "path separators neutralized, leading dots dropped"
  )
  H.eq(store.sanitize("a/b"), "a_b", "slash neutralized")
  H.eq(store.sanitize("..."), "unnamed", "dots-only namespace does not escape")
  H.eq(store.cache_key("x"):sub(1, 10), "telemetry/", "namespaced under telemetry/")

  -- -------------------------------------------------------------------------
  -- counting, and exact restore on stop
  -- -------------------------------------------------------------------------
  do
    local mod = {
      add = function(a, b)
        return a + b
      end,
      sub = function(a, b)
        return a - b
      end,
    }
    local original_add = mod.add

    local t = telemetry.new({ namespace = ns("count"), persist = false })
    H.eq(t.wrap(mod, "m"), 2, "both functions registered")
    H.eq(mod.add, original_add, "wrap() alone installs nothing")

    t.start()
    H.ok(mod.add ~= original_add, "start() installs the wrapper")
    H.eq(mod.add(2, 3), 5, "wrapper is transparent")
    mod.add(1, 1)
    mod.sub(9, 4)

    local rep = t.report()
    H.eq(rep.total_calls, 3, "three calls counted")
    H.eq(rep.entries[1].key, "m.add", "busiest first")
    H.eq(rep.entries[1].calls, 2, "add counted twice")

    t.stop()
    H.eq(mod.add, original_add, "stop() restores the original object exactly")
    H.eq(t.report().total_calls, 3, "stop() keeps collected data")
    H.eq(t.is_running(), false, "not running after stop")
    H.eq(t.stop(), false, "second stop is a no-op, not an error")
    t.unwrap()
  end

  -- -------------------------------------------------------------------------
  -- multiple return values and varargs survive the wrapper
  -- -------------------------------------------------------------------------
  do
    local mod = {
      multi = function()
        return 1, nil, 3
      end,
      count = function(...)
        return select("#", ...)
      end,
    }
    local t = telemetry.new({ namespace = ns("passthrough"), persist = false })
    t.wrap(mod)
    t.start({ time = true })

    local a, b, c = mod.multi()
    H.eq(a, 1, "first return")
    H.eq(b, nil, "nil hole preserved")
    H.eq(c, 3, "trailing return preserved")
    H.eq(mod.count(1, nil, nil), 3, "arity preserved through the wrapper")

    t.stop()
    t.unwrap()
  end

  -- -------------------------------------------------------------------------
  -- scoping: only / except / filter
  -- -------------------------------------------------------------------------
  do
    local mod = { a = function() end, b = function() end, _priv = function() end }

    local t1 = telemetry.new({ namespace = ns("only"), persist = false })
    H.eq(t1.wrap(mod, nil, { only = { "a" } }), 1, "only wraps one")
    H.eq(t1.wrapped_keys()[1], "a", "the listed one")

    local t2 = telemetry.new({ namespace = ns("except"), persist = false })
    H.eq(t2.wrap(mod, nil, { except = { "a", "b" } }), 1, "except skips two")

    local t3 = telemetry.new({ namespace = ns("filter"), persist = false })
    H.eq(
      t3.wrap(mod, nil, {
        filter = function(name)
          return not name:match("^_")
        end,
      }),
      2,
      "filter drops the private one"
    )
  end

  -- -------------------------------------------------------------------------
  -- wrap_fn: a function with no table to hang it off
  -- -------------------------------------------------------------------------
  do
    local t = telemetry.new({ namespace = ns("fn"), persist = false })
    local traced = t.wrap_fn(function(x)
      return x * 2
    end, "double")

    H.eq(traced(21), 42, "dispatcher is transparent before start")
    t.start()
    H.eq(traced(4), 8, "dispatcher is transparent while running")
    t.stop()
    H.eq(traced(1), 2, "dispatcher still works after stop")

    H.eq(t.report().entries[1].calls, 1, "only the call while running was counted")
    t.unwrap()
  end

  -- -------------------------------------------------------------------------
  -- module-id resolution: a plain wrap() resolves only if the caller vouches
  -- for the prefix explicitly -- the prefix is a label, not necessarily a
  -- real module path, and a guess here is exactly the failure mode the
  -- documentation.nvim join has to avoid (see wrap_loaded's own resolution
  -- test further down, where the module path is never guessed either).
  -- -------------------------------------------------------------------------
  do
    local mod = { f = function() end }

    local t1 = telemetry.new({ namespace = ns("wrap_unresolved"), persist = false })
    t1.wrap(mod, "servers")
    H.eq(next(t1.resolved_modules()), nil, "a bare wrap() prefix resolves nothing")
    t1.unwrap()

    local t2 = telemetry.new({ namespace = ns("wrap_resolved"), persist = false })
    t2.wrap(mod, "servers", { module_id = "lsp.servers" })
    H.eq(
      t2.resolved_modules()["servers.f"],
      "lsp.servers",
      "an explicit module_id is honored for a plain wrap()"
    )
    t2.unwrap()
  end

  -- -------------------------------------------------------------------------
  -- shared wrap layer: two instances, one function
  -- -------------------------------------------------------------------------
  do
    local mod = {
      shared = function()
        return true
      end,
    }
    local original = mod.shared

    local outer = telemetry.new({ namespace = ns("outer"), persist = false })
    local inner = telemetry.new({ namespace = ns("inner"), persist = false })

    outer.wrap(mod, "o")
    outer.start()
    local after_outer = mod.shared

    inner.wrap(mod, "i")
    inner.start()
    H.eq(mod.shared, after_outer, "second instance reuses the one wrapper, no nesting")

    mod.shared()
    mod.shared()

    H.eq(outer.report().entries[1].calls, 2, "outer sees both calls")
    H.eq(inner.report().entries[1].calls, 2, "inner sees both calls, not four")

    -- The restore-ordering trap: inner detaching first must not leave the
    -- wrapper installed as if it were the original.
    inner.stop()
    H.ok(mod.shared ~= original, "still wrapped while one subscriber remains")
    outer.stop()
    H.eq(mod.shared, original, "last one out restores the true original")

    outer.unwrap()
    inner.unwrap()
  end

  -- -------------------------------------------------------------------------
  -- wrap_loaded: the whole loaded subtree, module-level scoping, stable keys
  -- -------------------------------------------------------------------------
  do
    -- A fake plugin: a thin façade plus the submodules that hold the real
    -- functions -- the shape wrap_loaded exists for.
    package.loaded["fakeplug"] = { facade = function() end }
    package.loaded["fakeplug.core"] = { a = function() end, b = function() end }
    package.loaded["fakeplug.bindings.actions"] = {
      go = function(x)
        return x
      end,
    }
    package.loaded["fakeplug.@types"] = { noise = function() end }
    package.loaded["fakeplugother"] = { must_not_match = function() end }

    local t = telemetry.new({ namespace = ns("loaded"), persist = false })
    local n, mods = t.wrap_loaded("fakeplug")
    H.eq(n, 5, "façade + every loaded submodule")
    H.eq(mods, 4, "four modules contributed")

    local keys = t.wrapped_keys()
    H.ok(vim.tbl_contains(keys, "facade"), "the prefix module itself keeps bare keys")
    H.ok(vim.tbl_contains(keys, "core.a"), "submodule keys drop the prefix")
    H.ok(
      vim.tbl_contains(keys, "bindings.actions.go"),
      "nested submodule keeps its full relative path"
    )
    H.eq(vim.tbl_contains(keys, "must_not_match"), false, "prefix match is on a dot boundary")
    t.unwrap()

    -- module_filter / module_except / module_only
    local t2 = telemetry.new({ namespace = ns("loaded_filter"), persist = false })
    local n2 = t2.wrap_loaded("fakeplug", {
      module_filter = function(name)
        return not name:match("@types")
      end,
    })
    H.eq(n2, 4, "module_filter drops the @types module")
    t2.unwrap()

    local t3 = telemetry.new({ namespace = ns("loaded_only"), persist = false })
    H.eq(
      t3.wrap_loaded("fakeplug", { module_only = { "fakeplug.bindings.actions" } }),
      1,
      "module_only narrows to one module"
    )
    H.eq(t3.wrapped_keys()[1], "bindings.actions.go", "and its key is still prefix-relative")
    t3.unwrap()

    local t4 = telemetry.new({ namespace = ns("loaded_except"), persist = false })
    H.eq(
      t4.wrap_loaded("fakeplug", { module_except = { "fakeplug.core", "fakeplug.@types" } }),
      2,
      "module_except removes whole modules"
    )
    t4.unwrap()

    -- per-function scoping still applies underneath the module scoping
    local t5 = telemetry.new({ namespace = ns("loaded_fn"), persist = false })
    H.eq(
      t5.wrap_loaded("fakeplug", { only = { "a", "go" } }),
      2,
      "only/except/filter still scope functions within each module"
    )
    t5.unwrap()

    -- counting + argument profiling by predicate over the structured key
    local t6 = telemetry.new({ namespace = ns("loaded_args"), persist = false })
    t6.wrap_loaded("fakeplug")
    t6.start({
      profile_args = function(key)
        return key:match("^bindings%.") ~= nil
      end,
    })
    package.loaded["fakeplug.bindings.actions"].go("/repo/x")
    package.loaded["fakeplug.bindings.actions"].go("/repo/x")
    package.loaded["fakeplug.core"].a()

    local by_key = {}
    for _, e in ipairs(t6.report().entries) do
      by_key[e.key] = e
    end
    H.eq(by_key["bindings.actions.go"].calls, 2, "predicate-selected function counted")
    H.eq(
      by_key["bindings.actions.go"].args[1].fingerprint,
      '("/repo/x")',
      "and its arguments were fingerprinted"
    )
    H.eq(by_key["core.a"].args, nil, "a key the predicate rejected has no argument profile")
    t6.stop()
    t6.unwrap()

    -- re-registering is a no-op, so calling wrap_loaded again to pick up
    -- newly-required modules cannot double-count
    local t7 = telemetry.new({ namespace = ns("loaded_again"), persist = false })
    local first = t7.wrap_loaded("fakeplug")
    H.eq(t7.wrap_loaded("fakeplug"), first, "second call re-registers the same targets")
    H.eq(#t7.wrapped_keys(), first, "target list did not grow")
    t7.start()
    package.loaded["fakeplug.core"].a()
    H.eq(t7.report().total_calls, 1, "one call is counted once, not twice")
    t7.stop()
    t7.unwrap()

    H.eq(t7.wrap_loaded(""), 0, "an empty prefix registers nothing")

    -- module-id resolution: every wrap_loaded() key is derived from a real
    -- `package.loaded` path, so every one of them resolves.
    local t8 = telemetry.new({ namespace = ns("loaded_modules"), persist = false })
    t8.wrap_loaded("fakeplug")
    local resolved = t8.resolved_modules()
    H.eq(resolved.facade, "fakeplug", "the prefix module itself resolves to the prefix path")
    H.eq(resolved["core.a"], "fakeplug.core", "a submodule key resolves to its real module path")
    H.eq(
      resolved["bindings.actions.go"],
      "fakeplug.bindings.actions",
      "a nested submodule key resolves too"
    )
    t8.unwrap()

    for _, name in ipairs({
      "fakeplug",
      "fakeplug.core",
      "fakeplug.bindings.actions",
      "fakeplug.@types",
      "fakeplugother",
    }) do
      package.loaded[name] = nil
    end
  end

  -- -------------------------------------------------------------------------
  -- argument fingerprinting
  -- -------------------------------------------------------------------------
  H.eq(fingerprint.of(0), "()", "no arguments")
  H.eq(fingerprint.value(true), "true", "boolean by value")
  H.eq(fingerprint.value({ 1, 2, 3 }), "<table:#3>", "table by shape, not contents")
  H.eq(fingerprint.value({}), "<table:empty>", "empty table")
  H.eq(fingerprint.value(print), "<function>", "function by type")
  H.ok(#fingerprint.value(("x"):rep(500)) < 60, "long strings truncated rather than stored whole")

  do
    local mod = {
      find = function(path)
        return path
      end,
    }
    local t = telemetry.new({ namespace = ns("args"), persist = false })
    t.wrap(mod, "fs")
    t.start({ profile_args = { "fs.find" } })

    for _ = 1, 19 do
      mod.find("/repo/lib.nvim")
    end
    mod.find("/repo/other")

    local entry = t.report().entries[1]
    H.eq(entry.calls, 20, "all calls counted")
    H.eq(entry.args[1].fingerprint, '("/repo/lib.nvim")', "dominant fingerprint first")
    H.eq(entry.args[1].count, 19, "dominant count")
    H.ok(entry.hint ~= nil, "dominant argument produces the memoization hint")
    H.ok(entry.hint:find("memo", 1, true) ~= nil, "hint points at lib.lua.memo")

    t.stop()
    t.unwrap()
  end

  -- bounded cardinality: distinct fingerprints do not grow without limit
  do
    local mod = {
      f = function(x)
        return x
      end,
    }
    local t = telemetry.new({ namespace = ns("bounded"), persist = false, max_arg_values = 4 })
    t.wrap(mod)
    t.start({ profile_args = true })
    for i = 1, 50 do
      mod.f(i)
    end
    t.stop()

    local entry = t.report().entries[1]
    H.eq(#entry.args, 4, "kept exactly max_arg_values distinct fingerprints")
    H.eq(entry.other, 46, "the rest landed in the other bucket")
    H.eq(entry.distinct, 50, "distinct count still reported honestly")
    t.unwrap()
  end

  -- -------------------------------------------------------------------------
  -- call trees (docs/ROADMAP.md §3.1) — the immediate caller, one frame of
  -- debug.getinfo, reusing the identical bounded-cardinality bucket
  -- argument profiling already uses.
  -- -------------------------------------------------------------------------
  do
    local mod = {
      find = function(path)
        return path
      end,
    }
    local t = telemetry.new({ namespace = ns("call_tree"), persist = false })
    t.wrap(mod, "fs", { call_tree = true })
    t.start()

    -- Two distinct call sites, each on its own line -- real line numbers,
    -- not fabricated ones, so this exercises the real debug.getinfo call
    -- rather than a stand-in for it.
    local function caller_a()
      mod.find("/repo/a") -- line X
    end
    local function caller_b()
      mod.find("/repo/b") -- line Y
    end
    for _ = 1, 7 do
      caller_a()
    end
    for _ = 1, 3 do
      caller_b()
    end

    local entry = t.report().entries[1]
    H.eq(entry.calls, 10, "all calls counted regardless of caller")
    H.ok(entry.callers ~= nil, "callers bucket present once call_tree is on")
    H.eq(#entry.callers, 2, "exactly two distinct call sites")
    H.eq(entry.callers[1].count, 7, "the busier call site sorts first")
    H.ok(
      entry.callers[1].fingerprint:find("telemetry_spec%.lua:%d+$") ~= nil,
      "fingerprint is a real short_src:line, not a placeholder: got "
        .. entry.callers[1].fingerprint
    )
    H.ok(
      entry.callers[1].fingerprint ~= entry.callers[2].fingerprint,
      "the two call sites are genuinely distinct lines"
    )
    H.eq(entry.callers[1].share, 0.7, "share is of calls, 7/10")

    t.stop()
    t.unwrap()
  end

  -- opt-in via start_opts, same predicate/list/true shapes profile_args
  -- already supports, resolved through the identical `selected()` helper.
  do
    local mod = {
      find = function() end,
      quiet = function() end,
    }
    local t = telemetry.new({ namespace = ns("call_tree_predicate"), persist = false })
    t.wrap(mod, "fs")
    t.start({
      call_tree = function(key)
        return key == "fs.find"
      end,
    })

    local function somewhere()
      mod.find()
      mod.quiet()
    end
    somewhere()

    local by_key = {}
    for _, e in ipairs(t.report().entries) do
      by_key[e.key] = e
    end
    H.ok(by_key["fs.find"].callers ~= nil, "the selected key gets a callers bucket")
    H.eq(by_key["fs.quiet"].callers, nil, "a key the predicate rejected has no callers bucket")

    t.stop()
    t.unwrap()
  end

  -- bounded cardinality: reuses `accumulate()`, but confirmed end to end
  -- through the real call_tree path rather than assumed from the args test
  -- above sharing the same function.
  do
    local mod = {
      f = function() end,
    }
    local t = telemetry.new({
      namespace = ns("call_tree_bounded"),
      persist = false,
      max_arg_values = 3,
    })
    t.wrap(mod, nil, { call_tree = true })
    t.start()

    -- Five distinct call sites, each its own line, so the caller keys are
    -- genuinely five different fingerprints rather than one repeated five
    -- times.
    local function site1()
      mod.f()
    end
    local function site2()
      mod.f()
    end
    local function site3()
      mod.f()
    end
    local function site4()
      mod.f()
    end
    local function site5()
      mod.f()
    end
    site1()
    site2()
    site3()
    site4()
    site5()

    local entry = t.report().entries[1]
    H.eq(entry.calls, 5, "all five calls counted")
    H.eq(#entry.callers, 3, "kept exactly max_arg_values distinct call sites")
    H.eq(entry.callers_other, 2, "the rest landed in the other bucket")
    H.eq(entry.callers_distinct, 5, "distinct count still reported honestly")

    t.stop()
    t.unwrap()
  end

  -- sampling (docs/ROADMAP.md §3.2) applies to call_tree exactly as it
  -- already does to args/time/errors — only every Nth call pays for it.
  do
    local mod = {
      f = function() end,
    }
    local t = telemetry.new({ namespace = ns("call_tree_sample"), persist = false })
    t.wrap(mod, nil, { call_tree = true, sample = 5 })
    t.start()
    for _ = 1, 20 do
      mod.f()
    end
    local entry = t.report().entries[1]
    H.eq(entry.calls, 20, "calls itself is always exact, sampled or not")
    local sampled_total = 0
    for _, c in ipairs(entry.callers) do
      sampled_total = sampled_total + c.count
    end
    H.eq(sampled_total, 4, "only 1-in-5 calls paid for the caller lookup")
    t.stop()
    t.unwrap()
  end

  -- markdown rendering
  do
    local namespace = ns("call_tree_markdown")
    local mod = {
      find = function() end,
    }
    local t = telemetry.new({ namespace = namespace, persist = false })
    t.wrap(mod, "fs", { call_tree = true })
    t.start()
    mod.find()
    mod.find()

    local text = table.concat(t.markdown(), "\n")
    H.ok(
      text:find("### `fs.find` — callers", 1, true) ~= nil,
      "callers subsection for a call_tree-enabled function"
    )
    H.ok(text:find("| Share | Call site |", 1, true) ~= nil, "callers table header present")

    t.stop()
    t.unwrap()
  end

  -- -------------------------------------------------------------------------
  -- timing and error counting
  -- -------------------------------------------------------------------------
  do
    local mod = {
      slow = function()
        local x = 0
        for i = 1, 20000 do
          x = x + i
        end
        return x
      end,
      boom = function()
        error("nope")
      end,
    }
    local t = telemetry.new({ namespace = ns("timing"), persist = false })
    t.wrap(mod)
    t.start({ time = { "slow" }, errors = { "boom" } })

    mod.slow()
    mod.slow()
    local ok = pcall(mod.boom)
    H.eq(ok, false, "errors still propagate through the wrapper")

    local rep = t.report()
    local by_key = {}
    for _, e in ipairs(rep.entries) do
      by_key[e.key] = e
    end
    H.ok(by_key.slow.mean_ms ~= nil, "timing recorded")
    H.ok(by_key.slow.mean_ms >= 0, "mean is a number")
    H.eq(by_key.boom.errors, 1, "raised error counted")
    H.eq(rep.modes.timing, true, "report states it collected timing")
    H.eq(rep.modes.errors, true, "report states it collected errors")

    t.stop()
    t.unwrap()
  end

  -- -------------------------------------------------------------------------
  -- error fingerprinting (docs/ROADMAP.md §2.5): the same bounded-cardinality
  -- machinery `profile_args` already uses, pointed at the raised error's own
  -- value instead of the call's arguments.
  -- -------------------------------------------------------------------------
  do
    local mod = {
      fetch = function(which)
        if which == "timeout" then
          error("connection timed out", 0)
        end
        error("not found", 0)
      end,
    }
    local t = telemetry.new({ namespace = ns("error_fp"), persist = false })
    t.wrap(mod)
    t.start({ errors = true })

    for _ = 1, 3 do
      pcall(mod.fetch, "timeout")
    end
    pcall(mod.fetch, "missing")

    local entry = t.report().entries[1]
    H.eq(entry.errors, 4, "every raised error still counted, same as before this existed")
    H.ok(entry.error_fp ~= nil, "distinct error messages are fingerprinted")
    H.eq(entry.error_fp[1].fingerprint, '"connection timed out"', "dominant error message first")
    H.eq(entry.error_fp[1].count, 3, "dominant error's own count")
    H.eq(entry.error_fp[1].share, 3 / 4, "share computed against errors, not total calls")
    H.eq(
      entry.error_fp[2].fingerprint,
      '"not found"',
      "the other distinct error also fingerprinted"
    )
    H.eq(entry.error_fp[2].count, 1, "... with its own real count")
    H.eq(entry.error_other or 0, 0, "nothing evicted — well within max_arg_values")

    t.stop()
    t.unwrap()
  end

  -- error fingerprinting: a passing call must never populate error_fp, and a
  -- function with no `errors` opt-in at all must never populate it either
  -- (mirrors profile_args' own strict opt-in, docs/ROADMAP.md §2.5's own
  -- "reuses the existing machinery" framing extended to this too).
  do
    local mod = {
      ok_fn = function()
        return "fine"
      end,
      quiet_boom = function()
        error("nobody asked for this", 0)
      end,
    }
    local t = telemetry.new({ namespace = ns("error_fp_optin"), persist = false })
    t.wrap(mod)
    -- Only ok_fn opts into `errors`; quiet_boom does not.
    t.start({ errors = { "ok_fn" } })

    mod.ok_fn()
    pcall(mod.quiet_boom)

    local by_key = {}
    for _, e in ipairs(t.report().entries) do
      by_key[e.key] = e
    end
    H.eq(by_key.ok_fn.error_fp, nil, "a call that never errors has no error profile")
    H.eq(by_key.quiet_boom.errors, 0, "not opted into errors — not even the plain count")
    H.eq(by_key.quiet_boom.error_fp, nil, "... and certainly no fingerprint")

    t.stop()
    t.unwrap()
  end

  -- error fingerprinting: bounded cardinality, the identical discipline the
  -- argument-fingerprinting test above already proves for `s.args`.
  do
    local mod = {
      f = function(i)
        error("boom " .. i, 0)
      end,
    }
    local t =
      telemetry.new({ namespace = ns("error_bounded"), persist = false, max_arg_values = 4 })
    t.wrap(mod)
    t.start({ errors = true })
    for i = 1, 50 do
      pcall(mod.f, i)
    end
    t.stop()

    local entry = t.report().entries[1]
    H.eq(entry.errors, 50, "every error still counted despite the fingerprint cap")
    H.eq(#entry.error_fp, 4, "kept exactly max_arg_values distinct error fingerprints")
    H.eq(entry.error_other, 46, "the rest landed in the other bucket")
    H.eq(entry.error_distinct, 50, "distinct count still reported honestly")
    t.unwrap()
  end

  -- error fingerprinting: survives a flush + reload, and merges across two
  -- instances the same way `s.args`/`s.calls` already do (see the
  -- "persistence: merge-on-write" block further down for the pattern this
  -- mirrors).
  do
    local namespace = ns("error_fp_persist")
    local mod = {
      f = function()
        error("disk full", 0)
      end,
    }

    local t1 = telemetry.new({ namespace = namespace, persist = true, dir = tmpdir })
    t1.reset()
    t1.wrap(mod)
    t1.start({ errors = true })
    pcall(mod.f)
    t1.stop() -- flushes
    t1.unwrap()

    local on_disk = store.load(namespace, { dir = tmpdir })
    H.eq(
      on_disk.functions.f.error_fp.values['"disk full"'],
      1,
      "error fingerprint reached the disk"
    )

    local t2 = telemetry.new({ namespace = namespace, persist = true, dir = tmpdir })
    t2.wrap(mod)
    t2.start({ errors = true })
    pcall(mod.f)
    t2.stop()
    t2.unwrap()

    H.eq(
      store.load(namespace, { dir = tmpdir }).functions.f.error_fp.values['"disk full"'],
      2,
      "error fingerprint counts merged across sessions, not overwritten"
    )
    t2.reset()
  end

  -- -------------------------------------------------------------------------
  -- sampling (docs/ROADMAP.md §3.2): only every Nth call pays for the
  -- expensive modes; `calls` itself stays exact regardless.
  -- -------------------------------------------------------------------------
  do
    local mod = {
      f = function(x)
        return x
      end,
    }
    local t = telemetry.new({ namespace = ns("sample"), persist = false })
    t.wrap(mod, nil, { profile_args = true, sample = 4 })
    t.start()

    for i = 1, 20 do
      mod.f(i)
    end

    local entry = t.report().entries[1]
    H.eq(entry.calls, 20, "sample: calls is exact, sampling never touches the cheap counter")
    -- Sampled on the 4th, 8th, 12th, 16th, 20th call -- 5 of 20.
    local args_sum = 0
    for _, a in ipairs(entry.args) do
      args_sum = args_sum + a.count
    end
    args_sum = args_sum + (entry.other or 0)
    H.eq(args_sum, 5, "sample: only 1-in-4 calls were actually fingerprinted")

    t.stop()
    t.unwrap()
  end

  -- sampling: errors are subject to the same rate as args/time -- both
  -- ride the same site-level decision, since both cost a pcall/fingerprint
  -- only on the sampled subset.
  do
    local mod = {
      boom = function()
        error("x", 0)
      end,
    }
    local t = telemetry.new({ namespace = ns("sample_errors"), persist = false })
    t.wrap(mod, nil, { errors = true, sample = 5 })
    t.start()

    for _ = 1, 20 do
      pcall(mod.boom)
    end

    local entry = t.report().entries[1]
    H.eq(entry.calls, 20, "sample+errors: calls still exact")
    H.eq(entry.errors, 4, "sample+errors: only the sampled 1-in-5 calls counted as errors")

    t.stop()
    t.unwrap()
  end

  -- sampling: a dominant argument fingerprint still triggers the
  -- memoization hint under sampling -- the share/min-calls guard have to
  -- be computed against the *fingerprinted* sample, not the true call
  -- count, or a real dominant pattern would never be visible once sampled.
  do
    local mod = {
      find = function(path)
        return path
      end,
    }
    local t = telemetry.new({ namespace = ns("sample_dominant"), persist = false })
    t.wrap(mod, "fs", { profile_args = true, sample = 10 })
    t.start()

    for _ = 1, 500 do
      -- 1-in-10 sampled = 50 fingerprinted calls, all identical -- well
      -- past DOMINANT_MIN_CALLS (20) if measured against the *sample*,
      -- but far short of it against the true 500 calls at a naive
      -- calls-based threshold divided by the same rate.
      mod.find("/repo/lib.nvim")
    end

    local entry = t.report().entries[1]
    H.eq(entry.calls, 500, "sample_dominant: true call count unaffected")
    H.ok(entry.args ~= nil, "sample_dominant: fingerprinting happened on the sampled subset")
    H.eq(
      entry.args[1].share,
      1.0,
      "sample_dominant: share is 100% of the *sample*, not the true calls"
    )
    H.ok(entry.hint ~= nil, "sample_dominant: the memoization hint still fires under sampling")

    t.stop()
    t.unwrap()
  end

  -- sampling: two subscribers on the identical function, different rates
  -- -- the site uses the more eager (smaller) of the two, so neither
  -- subscriber is starved below what it asked for.
  do
    local mod = {
      f = function() end,
    }
    local t1 = telemetry.new({ namespace = ns("sample_multi_a"), persist = false })
    local t2 = telemetry.new({ namespace = ns("sample_multi_b"), persist = false })
    t1.wrap(mod, nil, { time = true, sample = 2 })
    t2.wrap(mod, nil, { time = true, sample = 5 })
    t1.start()
    t2.start()

    for _ = 1, 10 do
      mod.f()
    end

    local e1 = t1.report().entries[1]
    local e2 = t2.report().entries[1]
    H.eq(e1.calls, 10, "sample_multi: t1's call count exact")
    H.eq(e2.calls, 10, "sample_multi: t2's call count exact")
    -- Combined rate is min(2, 5) = 2 -- 5 sampled calls out of 10, and
    -- BOTH subscribers see every one of them (dispatch fans the same
    -- sampled call out to every subscriber, not just the one that asked
    -- for that particular rate).
    H.ok(e1.mean_ms ~= nil, "sample_multi: t1 (rate 2) got timing data")
    H.ok(e2.mean_ms ~= nil, "sample_multi: t2 (rate 5, less eager) still got timing data")

    t1.stop()
    t2.stop()
    t1.unwrap()
  end

  -- -------------------------------------------------------------------------
  -- track_table: per-key read/write counting via explicit get/set functions,
  -- not a transparent proxy (see the module's own doc-comment for why: a
  -- __index/__newindex proxy would break pairs()/ipairs()/# on the wrapped
  -- table permanently, which this deliberately avoids).
  -- -------------------------------------------------------------------------
  do
    local config = { host = "localhost", port = 8080 }
    local t = telemetry.new({ namespace = ns("track_table"), persist = false })
    t.start()

    local get, set = t.track_table(config, "config")

    H.eq(get("host"), "localhost", "track_table: get() returns the real value")
    get("host")
    get("host")
    get("port")

    set("host", "example.com")
    H.eq(config.host, "example.com", "track_table: set() actually writes through to the real table")

    local rep = t.report()
    local by_key = {}
    for _, e in ipairs(rep.entries) do
      by_key[e.key] = e
    end
    H.eq(by_key["config[host] read"].calls, 3, "track_table: read count is per-field")
    H.eq(by_key["config[port] read"].calls, 1, "track_table: a different field has its own count")
    H.eq(
      by_key["config[host] write"].calls,
      1,
      "track_table: write count is separate from read count"
    )
    H.ok(
      by_key["config[port] write"] == nil,
      "track_table: a field never written has no write entry at all"
    )

    -- The table itself is never touched — a plain table before and after,
    -- fully enumerable, the entire point of not proxying it.
    local keys = {}
    for k in pairs(config) do
      keys[#keys + 1] = k
    end
    table.sort(keys)
    H.eq(#keys, 2, "track_table: the real table still has exactly its own two keys")
    H.eq(keys[1], "host", "track_table: pairs() still works normally — 'host' present")
    H.eq(keys[2], "port", "track_table: pairs() still works normally — 'port' present")

    t.stop()
    t.unwrap()
  end

  -- track_table: reads/writes can be independently disabled, and repeated
  -- access to the same field reuses one registry site rather than leaking a
  -- new one per call (the same "wrap once per distinct key" discipline
  -- runtime-analysis.usage's own command counting already relies on).
  do
    local data = { x = 1 }
    local t = telemetry.new({ namespace = ns("track_table_opts"), persist = false })
    t.start()

    local get_only = select(1, t.track_table(data, "reads_only", { writes = false }))
    get_only("x")
    local rep1 = t.report()
    local has_write_entry = false
    for _, e in ipairs(rep1.entries) do
      if e.key:find("write", 1, true) then
        has_write_entry = true
      end
    end
    H.ok(not has_write_entry, "track_table: writes = false records no write entries at all")

    local _, set_only = t.track_table(data, "writes_only", { reads = false })
    for _ = 1, 25 do
      set_only("y", 2)
    end
    local rep2 = t.report()
    local by_key2 = {}
    for _, e in ipairs(rep2.entries) do
      by_key2[e.key] = e
    end
    H.eq(
      by_key2["writes_only[y] write"].calls,
      25,
      "track_table: repeated access to the same field accumulates on one entry, not 25 separate ones"
    )

    t.stop()
    t.unwrap()
  end

  -- -------------------------------------------------------------------------
  -- recursion: every entry by default, outermost only on request
  -- -------------------------------------------------------------------------
  do
    local mod = {}
    mod.down = function(n)
      if n <= 0 then
        return 0
      end
      return mod.down(n - 1)
    end

    local t = telemetry.new({ namespace = ns("recursive"), persist = false })
    t.wrap(mod)
    t.start()
    mod.down(3)
    H.eq(t.report().entries[1].calls, 4, "every entry counted by default")
    t.stop()
    t.unwrap()

    local mod2 = {}
    mod2.down = function(n)
      if n <= 0 then
        return 0
      end
      return mod2.down(n - 1)
    end
    local t2 = telemetry.new({ namespace = ns("outermost"), persist = false })
    t2.wrap(mod2, nil, { outermost_only = true })
    t2.start()
    mod2.down(3)
    H.eq(t2.report().entries[1].calls, 1, "outermost_only collapses the chain")
    t2.stop()
    t2.unwrap()
  end

  -- -------------------------------------------------------------------------
  -- coverage: the never-called set
  -- -------------------------------------------------------------------------
  do
    local mod = { used = function() end, unused = function() end }
    local t = telemetry.new({ namespace = ns("coverage"), persist = false })
    t.wrap(mod)
    t.start()
    mod.used()
    t.stop()

    local cov = t.coverage()
    H.eq(#cov.called, 1, "one called")
    H.eq(cov.called[1], "used", "the right one")
    H.eq(cov.uncalled[1], "unused", "dead surface surfaced")
    t.unwrap()
  end

  -- -------------------------------------------------------------------------
  -- persistence: merge-on-write, not last-write-wins
  -- -------------------------------------------------------------------------
  do
    local namespace = ns("persist")
    local mod = { f = function() end }

    local t1 = telemetry.new({ namespace = namespace, persist = true, dir = tmpdir })
    t1.reset()
    t1.wrap(mod)
    t1.start()
    mod.f()
    mod.f()
    t1.stop() -- flushes
    t1.unwrap()

    local on_disk = store.load(namespace, { dir = tmpdir })
    H.eq(on_disk.functions.f.calls, 2, "counts reached the disk")

    -- A second process (same namespace, fresh instance) must add to that.
    -- The "already has a live instance" warning this prints is the point of
    -- question 5 in the concept doc, and is expected here.
    local t2 = telemetry.new({ namespace = namespace, persist = true, dir = tmpdir })
    H.eq(t2.report().total_calls, 2, "previous run's counts loaded back")
    t2.wrap(mod)
    t2.start()
    mod.f()
    t2.stop()
    t2.unwrap()

    H.eq(store.load(namespace, { dir = tmpdir }).functions.f.calls, 3, "merged, not overwritten")
    H.eq(store.load(namespace, { dir = tmpdir }).sessions, 2, "session counter advanced")

    t2.reset()
    H.eq(store.load(namespace, { dir = tmpdir }).functions.f, nil, "reset clears the disk copy")
  end

  -- -------------------------------------------------------------------------
  -- cache-directory default: an instance with no explicit `dir` must resolve
  -- under THIS plugin's own cache root, not lib.nvim's — the actual data,
  -- not just report/export cosmetics, would otherwise keep landing in the
  -- wrong place after the module moved.
  -- -------------------------------------------------------------------------
  do
    local t = telemetry.new({ namespace = ns("cache_dir_default"), persist = false })
    H.eq(
      t._cache_opts.dir,
      vim.fn.stdpath("cache") .. "/runtime-analysis.nvim/cache",
      "no opts.dir given -> resolves under runtime-analysis.nvim's cache root"
    )
  end

  -- -------------------------------------------------------------------------
  -- reset(): the module-id map is repopulated from the still-wrapped targets
  -- immediately, not left empty until something calls wrap() again -- reset()
  -- promises "wrapping is untouched", and the module map is a property of the
  -- wrapping, not of the counts it clears.
  -- -------------------------------------------------------------------------
  do
    local namespace = ns("reset_modules")
    package.loaded["fakeplug_reset"] = { go = function() end }

    local t = telemetry.new({ namespace = namespace, persist = true, dir = tmpdir })
    t.wrap_loaded("fakeplug_reset")
    t.start()
    package.loaded["fakeplug_reset"].go()
    t.stop() -- flush #1: counts and module map both on disk

    t.reset() -- clears memory + disk; wrapping (targets) is untouched
    H.eq(
      t.resolved_modules().go,
      "fakeplug_reset",
      "resolved_modules() reflects current targets right after reset()"
    )

    t.flush()
    H.eq(
      store.load_readonly(namespace, { dir = tmpdir }).modules.go,
      "fakeplug_reset",
      "the module-id map is back on disk after the next flush, without re-wrapping"
    )
    H.eq(
      store.load_readonly(namespace, { dir = tmpdir }).functions.go,
      nil,
      "counts stayed cleared -- only the module map was carried forward"
    )

    t.unwrap()
    package.loaded["fakeplug_reset"] = nil
  end

  -- -------------------------------------------------------------------------
  -- telemetry.load() / store.load_readonly(): read a namespace off disk with
  -- no live instance, distinguishing "never persisted" (nil) from "persisted,
  -- zero calls" -- the distinction documentation.nvim's join depends on so an
  -- unanalyzed tree renders as "no data", not a graveyard.
  -- -------------------------------------------------------------------------
  do
    local namespace = ns("readonly")

    H.eq(store.load_readonly(namespace, { dir = tmpdir }), nil, "nothing on disk yet")
    H.eq(telemetry.load(namespace, { dir = tmpdir }), nil, "module-level load() agrees")

    package.loaded["fakeplug_ro"] = { go = function() end }
    local t = telemetry.new({ namespace = namespace, persist = true, dir = tmpdir })
    t.wrap_loaded("fakeplug_ro")
    t.start()
    package.loaded["fakeplug_ro"].go()
    t.stop() -- flushes
    t.unwrap()
    package.loaded["fakeplug_ro"] = nil

    local disk_readonly = store.load_readonly(namespace, { dir = tmpdir })
    H.ok(disk_readonly ~= nil, "data now exists on disk")
    H.eq(disk_readonly.functions.go.calls, 1, "counts round-trip")
    H.eq(disk_readonly.modules.go, "fakeplug_ro", "the module-id map round-trips too")

    local loaded = telemetry.load(namespace, { dir = tmpdir })
    H.eq(loaded.functions.go.calls, 1, "telemetry.load() sees the same data, no instance required")
    H.eq(loaded.modules.go, "fakeplug_ro", "...including the module map")

    H.eq(
      telemetry.load(nil, { dir = tmpdir }),
      nil,
      "a non-string namespace is refused, not errored on"
    )
    H.eq(telemetry.load("", { dir = tmpdir }), nil, "an empty namespace is refused too")
  end

  -- -------------------------------------------------------------------------
  -- day buckets: `since` windows and retention pruning
  -- -------------------------------------------------------------------------
  do
    H.eq(store.parse_since("7d"), 7, "7d")
    H.eq(store.parse_since("24h"), 1, "24h rounds to a day")
    H.eq(store.parse_since("2w"), 14, "2w")
    H.eq(store.parse_since(3), 3, "bare number")
    H.eq(store.parse_since(nil), nil, "nil means no window")

    local data = store.empty()
    data.days[store.today()] = { recent = 5 }
    data.days[os.date("%Y-%m-%d", os.time() - 40 * 86400)] = { old = 7 }

    local windowed, total = store.since(data, 7)
    H.eq(total, 5, "only the in-window day counts")
    H.eq(windowed.old, nil, "old day excluded")

    H.eq(store.prune(data, 30), 1, "one stale bucket dropped")
    H.eq(store.count_keys(data.days), 1, "today's bucket kept")
  end

  -- -------------------------------------------------------------------------
  -- comparison across time windows (docs/ROADMAP.md §4.2): "this week vs
  -- last week" — pure logic first (store.previous_window, report.compare),
  -- then one end-to-end pass through a real instance.
  -- -------------------------------------------------------------------------
  local report_mod = require("runtime-analysis.telemetry.report")
  do
    local data = store.empty()
    local function ago(days)
      return os.date("%Y-%m-%d", os.time() - days * 86400)
    end
    -- current window (last 7d): f=10 (today), g=5 (day 3)
    data.days[ago(0)] = { f = 10 }
    data.days[ago(3)] = { g = 5 }
    -- previous window (7-14d ago): f=4 (day 10), h=8 (day 12)
    data.days[ago(10)] = { f = 4 }
    data.days[ago(12)] = { h = 8 }
    -- well outside either window
    data.days[ago(40)] = { ancient = 100 }

    local prev, prev_total = store.previous_window(data, 7)
    H.eq(prev_total, 12, "previous_window sums only the 7-14 day-ago range")
    H.eq(prev.f, 4, "a key present in both windows, previous-window count only")
    H.eq(prev.h, 8, "a key only in the previous window")
    H.eq(prev.g, nil, "a key only in the current window is absent here")
    H.eq(prev.ancient, nil, "a bucket older than the previous window is excluded")

    local current, current_total = store.since(data, 7)
    H.eq(current_total, 15, "sanity — since() still sums the current window as before")
    H.eq(current.f, 10, "sanity — current window's own count for f")

    local cmp = report_mod.compare(data, { days = 7 })
    H.eq(cmp.current_total, 15, "compare: current_total matches since()")
    H.eq(cmp.previous_total, 12, "compare: previous_total matches previous_window()")

    local by_key = {}
    for _, list in ipairs({ cmp.new_functions, cmp.cold_functions, cmp.changed }) do
      for _, e in ipairs(list) do
        by_key[e.key] = e
      end
    end
    H.ok(by_key.g ~= nil, "g (only in current) is classified")
    H.eq(by_key.g.current, 5, "g: current count")
    H.eq(by_key.g.previous, 0, "g: previous count is 0, not nil, once classified")
    local g_is_new = vim.tbl_contains(
      vim.tbl_map(function(e)
        return e.key
      end, cmp.new_functions),
      "g"
    )
    H.ok(g_is_new, "g: classified as newly hot (silent before, called now)")

    local h_is_cold = vim.tbl_contains(
      vim.tbl_map(function(e)
        return e.key
      end, cmp.cold_functions),
      "h"
    )
    H.ok(h_is_cold, "h (only in previous) classified as gone cold")

    local f_is_changed = vim.tbl_contains(
      vim.tbl_map(function(e)
        return e.key
      end, cmp.changed),
      "f"
    )
    H.ok(f_is_changed, "f (in both) classified as changed, not new or cold")
    H.eq(by_key.f.current, 10, "f: current count")
    H.eq(by_key.f.previous, 4, "f: previous count")
    H.eq(by_key.f.delta, 6, "f: delta is current - previous")
    H.eq(by_key.f.delta_pct, 6 / 4, "f: delta_pct relative to previous")

    H.eq(cmp.incomplete_previous_window, false, "retention_days (unset) never flags incomplete")
    local cmp_flagged = report_mod.compare(data, { days = 20, retention_days = 30 })
    H.eq(
      cmp_flagged.incomplete_previous_window,
      true,
      "2x a 20-day window exceeds a 30-day retention — flagged, not silently wrong"
    )

    -- Rendering doesn't error and mentions the window size.
    local lines = report_mod.compare_lines(cmp)
    H.ok(#lines > 0, "compare_lines produces output")
    H.ok(lines[1]:find("7d", 1, true) ~= nil, "compare_lines names the window size")
    local md = report_mod.compare_markdown(cmp)
    H.ok(#md > 0, "compare_markdown produces output")
  end

  -- End-to-end: a real instance, persisted day buckets fabricated directly
  -- on disk (the same technique the retention/pruning test above uses
  -- indirectly via store.empty()), t.compare() reading them back correctly.
  do
    local namespace = ns("compare_e2e")
    local data = store.empty()
    data.days[os.date("%Y-%m-%d", os.time())] = { ["mod.f"] = 9 }
    data.days[os.date("%Y-%m-%d", os.time() - 10 * 86400)] = { ["mod.f"] = 3 }
    data.functions["mod.f"] = { calls = 12 }
    store.save(namespace, data, { dir = tmpdir })

    local t = telemetry.new({ namespace = namespace, persist = true, dir = tmpdir })
    local cmp = t.compare({ days = 7 })
    H.eq(cmp.current_total, 9, "t.compare: current window read back correctly")
    H.eq(cmp.previous_total, 3, "t.compare: previous window read back correctly")

    local lines = t.compare_lines({ days = 7 })
    H.ok(#lines > 0, "t.compare_lines: produces output for a real instance")
    t.reset()
  end

  -- -------------------------------------------------------------------------
  -- lifecycle reminder: fires once, persists that it fired, escalates once
  -- -------------------------------------------------------------------------
  do
    local data = store.empty()
    data.functions.f = { calls = 60000 }

    H.eq(reminder.check("demo", data, false), nil, "remind_after = false opts out")

    local msg = reminder.check("demo", data, { days = 7, calls = 50000 })
    H.ok(msg ~= nil, "volume trigger fires")
    H.ok(msg:find(":RATelemetry demo", 1, true) ~= nil, "names the read command")
    H.ok(msg:find(":RATelemetry stop", 1, true) ~= nil, "names the stop command")
    H.eq(data.reminded.first, true, "fired state persisted into the cache entry")

    H.eq(reminder.check("demo", data, { days = 7, calls = 50000 }), nil, "does not repeat")

    data.started_at = os.time() - 40 * 86400
    local second = reminder.check("demo", data, { days = 7, calls = 50000 })
    H.ok(second ~= nil, "escalates once past 4x the duration")
    H.eq(reminder.check("demo", data, { days = 7, calls = 50000 }), nil, "then stops for good")
  end

  -- -------------------------------------------------------------------------
  -- module-level registry
  -- -------------------------------------------------------------------------
  do
    local namespace = ns("registry")
    local t = telemetry.new({ namespace = namespace, persist = false })
    H.eq(telemetry.get(namespace), t, "instance discoverable by namespace")
    H.ok(#telemetry.instances() > 0, "instances() enumerates")
  end

  -- report rendering must not throw on an empty instance
  do
    local t = telemetry.new({ namespace = ns("render"), persist = false })
    local lines = t.lines()
    H.ok(#lines > 0, "lines() renders something for an empty instance")
    H.ok(lines[1]:find("stopped", 1, true) ~= nil, "header reports the stopped state")
  end

  -- -------------------------------------------------------------------------
  -- toggle.lua: persistent disable, isolated from the real stdpath("cache")
  -- via an explicit dir (every function takes one for exactly this reason).
  -- -------------------------------------------------------------------------
  do
    local topts = { dir = tmpdir }
    local n1, n2 = ns("toggle_a"), ns("toggle_b")

    H.eq(toggle.is_disabled(n1, topts), false, "nothing disabled yet")
    toggle.disable(n1, topts)
    H.eq(toggle.is_disabled(n1, topts), true, "disable persists immediately")
    H.eq(toggle.is_disabled(n2, topts), false, "a different namespace is untouched")

    toggle.disable(n2, topts)
    local listed = toggle.disabled_list(topts)
    table.sort(listed)
    H.eq(#listed, 2, "disabled_list sees both")

    toggle.enable(n1, topts)
    H.eq(toggle.is_disabled(n1, topts), false, "enable clears it")
    H.eq(toggle.is_disabled(n2, topts), true, "enabling one leaves the other disabled")

    toggle.enable(n1, topts) -- enabling an already-enabled namespace: no-op, no error
    toggle.enable(n2, topts)
    H.eq(#toggle.disabled_list(topts), 0, "both cleared")
  end

  -- -------------------------------------------------------------------------
  -- disable/enable integration: inst.start() honors a persisted disable, and
  -- takes effect on a LIVE instance without the caller re-calling start().
  -- Isolated via dir=tmpdir (threaded into the same toggle checks above).
  -- -------------------------------------------------------------------------
  do
    local namespace = ns("toggle_integration")
    local mod = { f = function() end }

    -- Disabling before the instance exists: the common case (`:RATelemetry
    -- disable <ns>` for a plugin that has not loaded yet this session).
    telemetry.disable(namespace) -- module-level API has no dir param; see below

    -- Since the module-level disable() above has no way to know this
    -- instance will use `dir=tmpdir` (it doesn't exist yet), it persisted to
    -- the default cache — the documented edge case. Exercise the realistic
    -- path instead: disable AFTER the instance exists, which is what
    -- `:RATelemetry disable <ns>` actually does for an already-loaded
    -- plugin, and is the path that matters for "persistently toggle a
    -- running plugin".
    telemetry.enable(namespace) -- undo the pre-emptive (default-dir) disable above

    local t = telemetry.new({ namespace = namespace, persist = false, dir = tmpdir })
    t.wrap(mod)
    H.eq(t.start(), true, "starts normally before any disable")
    mod.f()

    telemetry.disable(namespace)
    H.eq(t.is_running(), false, "telemetry.disable() stops a live, running instance immediately")
    H.eq(
      toggle.is_disabled(namespace, t._cache_opts),
      true,
      "persisted under the instance's own dir"
    )

    H.eq(t.start(), false, "start() is a no-op while disabled")
    H.eq(t.is_running(), false, "...and does not report itself as running")

    telemetry.enable(namespace)
    H.eq(t.is_running(), true, "telemetry.enable() resumes it immediately")

    local report = t.report()
    H.eq(report.disabled, false, "report reflects the enabled state")

    telemetry.disable(namespace)
    H.eq(t.report().disabled, true, "report reflects the disabled state")

    t.unwrap()
    telemetry.enable(namespace) -- leave no persisted disable behind for this dir
  end

  -- -------------------------------------------------------------------------
  -- :RATelemetry — per-namespace start/stop/reset leave other instances alone
  -- -------------------------------------------------------------------------
  do
    require("runtime-analysis.telemetry.command").setup()

    local ns_a, ns_b = ns("cmd_a"), ns("cmd_b")
    local mod_a, mod_b = { f = function() end }, { g = function() end }
    local ta = telemetry.new({ namespace = ns_a, persist = false })
    local tb = telemetry.new({ namespace = ns_b, persist = false })
    ta.wrap(mod_a)
    tb.wrap(mod_b)
    ta.start()
    tb.start()
    mod_a.f()
    mod_b.g()

    vim.cmd("RATelemetry stop " .. ns_a)
    H.eq(ta.is_running(), false, ":RATelemetry stop <ns> stops only that instance")
    H.eq(tb.is_running(), true, "the other instance keeps running")

    vim.cmd("RATelemetry start " .. ns_a)
    H.eq(ta.is_running(), true, ":RATelemetry start <ns> restarts only that instance")

    vim.cmd("RATelemetry reset " .. ns_a)
    H.eq(ta.report().total_calls, 0, ":RATelemetry reset <ns> clears only that instance")
    H.eq(tb.report().total_calls, 1, "the other instance's data is untouched")

    -- Second-argument completion offers namespaces, not the subcommand list.
    local completions = vim.fn.getcompletion("RATelemetry stop ", "cmdline")
    H.ok(vim.tbl_contains(completions, ns_a), "namespace offered after 'stop '")
    H.eq(vim.tbl_contains(completions, "start"), false, "subcommands not repeated as a 2nd arg")

    local ok = pcall(vim.cmd, "RATelemetry stop does-not-exist")
    H.eq(ok, true, "an unknown namespace warns rather than erroring")

    ta.unwrap()
    tb.unwrap()
  end

  -- -------------------------------------------------------------------------
  -- :RATelemetry disable/enable/disabled — dir=tmpdir, isolated from the
  -- real stdpath("cache") the same way the toggle tests above are.
  -- -------------------------------------------------------------------------
  do
    local ns_a, ns_b = ns("cmd_disable_a"), ns("cmd_disable_b")
    local mod_a, mod_b = { f = function() end }, { g = function() end }
    local ta = telemetry.new({ namespace = ns_a, persist = false, dir = tmpdir })
    local tb = telemetry.new({ namespace = ns_b, persist = false, dir = tmpdir })
    ta.wrap(mod_a)
    tb.wrap(mod_b)
    ta.start()
    tb.start()

    vim.cmd("RATelemetry disable " .. ns_a)
    H.eq(ta.is_running(), false, ":RATelemetry disable <ns> stops that instance now")
    H.eq(tb.is_running(), true, "the other instance is untouched")
    H.eq(ta.start(), false, "start() stays a no-op while disabled, even called directly")

    local disabled_lines = {}
    local ok_report = pcall(function()
      disabled_lines = ta.report()
    end)
    H.eq(ok_report, true, "report() does not throw on a disabled instance")
    H.eq(disabled_lines.disabled, true, "report marks it disabled")

    vim.cmd("RATelemetry enable " .. ns_a)
    H.eq(ta.is_running(), true, ":RATelemetry enable <ns> resumes it now")

    local ok_unknown = pcall(vim.cmd, "RATelemetry disable does-not-exist")
    H.eq(ok_unknown, true, "disabling an unknown/not-yet-loaded namespace does not error")

    ta.unwrap()
    tb.unwrap()
  end

  -- -------------------------------------------------------------------------
  -- report.markdown(): the same report data M.lines renders, as GFM instead
  -- of terminal box-drawing. Built from the same M.build() result, so it
  -- cannot report different numbers than M.lines does.
  -- -------------------------------------------------------------------------
  do
    local namespace = ns("markdown")
    local mod = {
      find = function(path)
        return path
      end,
      quiet = function() end,
    }
    local t = telemetry.new({ namespace = namespace, persist = false })
    t.wrap(mod, "fs")
    t.start({ profile_args = { "fs.find" } })
    for _ = 1, 25 do
      mod.find("/repo/lib.nvim")
    end
    mod.find("/repo/other")
    mod.quiet()

    local text = table.concat(t.markdown(), "\n")
    H.ok(text:find("# " .. namespace .. " — telemetry", 1, true) ~= nil, "H1 names the namespace")
    H.ok(text:find("| Function | Calls | Ø ms | Errors |", 1, true) ~= nil, "table header present")
    H.ok(text:find("`fs.find`", 1, true) ~= nil, "busiest entry rendered as a table row")
    H.ok(
      text:find("### `fs.find` — argument profile", 1, true) ~= nil,
      "argument-profile subsection for a profiled function"
    )
    H.ok(text:find("candidate for", 1, true) ~= nil, "memoization hint carried into a blockquote")
    H.eq(
      text:find("### `fs.quiet`", 1, true),
      nil,
      "no argument-profile subsection for an unprofiled function"
    )

    t.stop()
    t.unwrap()
  end

  do
    local t = telemetry.new({ namespace = ns("markdown_empty"), persist = false })
    H.ok(
      vim.tbl_contains(t.markdown(), "_(no calls recorded)_"),
      "empty instance renders the no-data line, not an empty table"
    )
    t.unwrap()
  end

  -- -------------------------------------------------------------------------
  -- markdown_all(): combined document, one H1, each report's own heading
  -- demoted to H2 so the result is one well-formed file.
  -- -------------------------------------------------------------------------
  do
    local ns_a, ns_b = ns("md_all_a"), ns("md_all_b")
    local mod_a, mod_b = { f = function() end }, { g = function() end }
    local ta = telemetry.new({ namespace = ns_a, persist = false })
    local tb = telemetry.new({ namespace = ns_b, persist = false })
    ta.wrap(mod_a)
    tb.wrap(mod_b)
    ta.start()
    tb.start()
    mod_a.f()
    mod_b.g()

    local lines = telemetry.markdown_all()
    local text = table.concat(lines, "\n")
    H.eq(lines[1], "# runtime-analysis.nvim — telemetry", "one combined H1")
    H.eq(text:find("\n# ", 1, true), nil, "no second H1 -- per-report headings are demoted")
    H.ok(
      text:find("## " .. ns_a .. " — telemetry", 1, true) ~= nil,
      "first namespace's heading demoted to H2"
    )
    H.ok(
      text:find("## " .. ns_b .. " — telemetry", 1, true) ~= nil,
      "second namespace's heading demoted to H2"
    )
    H.ok(text:find("\n---\n", 1, true) ~= nil, "reports separated by a thematic break")

    ta.stop()
    tb.stop()
    ta.unwrap()
    tb.unwrap()
  end

  -- -------------------------------------------------------------------------
  -- report_file.lua: path resolution (dir-overridable, mirrors store.lua's
  -- own sanitize/cache_key convention) and best-effort disk writes.
  -- -------------------------------------------------------------------------
  do
    local report_file = require("runtime-analysis.telemetry.report_file")

    H.eq(report_file.dir({ dir = tmpdir }):sub(1, #tmpdir), tmpdir, "dir override is honored")
    H.ok(
      report_file.dir({ dir = tmpdir }):find("telemetry", 1, true) ~= nil,
      "lives under a telemetry/ subdir"
    )
    H.eq(
      report_file.namespace_path("lib.nvim", { dir = tmpdir }),
      report_file.dir({ dir = tmpdir }) .. "/lib.nvim.md",
      "namespace path is sanitize(namespace).md under dir()"
    )
    H.eq(
      report_file.combined_path({ dir = tmpdir }),
      report_file.dir({ dir = tmpdir }) .. "/report.md",
      "combined path is report.md under dir()"
    )

    local path = report_file.dir({ dir = tmpdir }) .. "/write_test.md"
    local ok, err = report_file.write(path, { "# hello", "", "world" })
    H.eq(ok, true, "write succeeds")
    H.eq(err, nil, "no error on success")

    local file = io.open(path, "r")
    H.ok(file ~= nil, "the file exists")
    local content = file:read("*a")
    file:close()
    H.eq(content, "# hello\n\nworld\n", "content round-trips, trailing newline added")
  end

  -- -------------------------------------------------------------------------
  -- report_file = true: keep this namespace's Markdown report on disk,
  -- rewritten at every flush -- what makes the mdview bridge self-updating.
  -- -------------------------------------------------------------------------
  do
    local namespace = ns("report_file_opt")
    local report_file = require("runtime-analysis.telemetry.report_file")
    local mod = { f = function() end }

    local t = telemetry.new({
      namespace = namespace,
      persist = false,
      dir = tmpdir,
      report_file = true,
    })
    t.wrap(mod)
    t.start()
    mod.f()
    t.flush()

    local path = report_file.namespace_path(namespace, { dir = tmpdir })
    local file = io.open(path, "r")
    H.ok(file ~= nil, "report_file = true writes a per-namespace file at flush")
    local content = file:read("*a")
    file:close()
    H.ok(content:find("| `f` | 1 |", 1, true) ~= nil, "the written report reflects current counts")

    mod.f()
    t.flush()
    local file2 = io.open(path, "r")
    local content2 = file2:read("*a")
    file2:close()
    H.ok(
      content2:find("| `f` | 2 |", 1, true) ~= nil,
      "rewritten on the next flush with updated counts"
    )

    t.stop()
    t.unwrap()
  end

  do
    local namespace = ns("report_file_off")
    local report_file = require("runtime-analysis.telemetry.report_file")
    local mod = { f = function() end }
    local t = telemetry.new({ namespace = namespace, persist = false, dir = tmpdir })
    t.wrap(mod)
    t.start()
    mod.f()
    t.flush()

    local path = report_file.namespace_path(namespace, { dir = tmpdir })
    H.eq(io.open(path, "r"), nil, "no file written when report_file is left at its false default")
    t.unwrap()
  end

  -- -------------------------------------------------------------------------
  -- report_style resolution: mdview.nvim is not on this test run's runtime
  -- path (docs/TESTS/run.lua only appends the lib.nvim repo itself), so
  -- "mdview"/"auto" deterministically fall back to "kit" here -- exactly the
  -- degrade-silently path a consumer without mdview installed hits for real.
  -- -------------------------------------------------------------------------
  do
    local resolve_style = require("runtime-analysis.telemetry.report_style")
    local mdview_renderer = require("runtime-analysis.telemetry.renderers.mdview")

    H.eq(mdview_renderer.available(), false, "mdview.nvim is not on rtp in this test run")

    H.eq(resolve_style("kit"), "kit", "explicit kit stays kit")
    H.eq(resolve_style("file"), "file", "explicit file stays file")
    H.eq(resolve_style("mdview"), "kit", "explicit mdview degrades to kit when unavailable")
    H.eq(resolve_style("auto"), "kit", "auto degrades to kit when mdview is unavailable")
    H.eq(resolve_style(nil), "kit", "nil behaves like auto")
    H.eq(resolve_style("nonsense"), "kit", "an unrecognized value behaves like auto")

    local ok, err = mdview_renderer.open({ "x" }, tmpdir .. "/mdview_open_test.md")
    H.eq(ok, false, "mdview.open() fails cleanly, not raising, when mdview is unavailable")
    H.ok(err ~= nil, "...with an explanatory error")
  end

  -- -------------------------------------------------------------------------
  -- telemetry.setup({ report_style = ... }): the one module-level default,
  -- separate from telemetry.new(opts) -- see config.lua for why.
  -- -------------------------------------------------------------------------
  do
    local config = require("runtime-analysis.telemetry.config")
    H.eq(config.report_style(), "auto", "auto is the default")
    telemetry.setup({ report_style = "file" })
    H.eq(config.report_style(), "file", "setup() overrides the module-level default")
    telemetry.setup({ report_style = "auto" })
    H.eq(config.report_style(), "auto", "setup() again restores it for the rest of this run")
  end

  -- -------------------------------------------------------------------------
  -- :RATelemetry export — format inferred from the target path's extension,
  -- not a separate flag (this command's argument parsing stays positional).
  -- -------------------------------------------------------------------------
  do
    local namespace = ns("export")
    local mod = { f = function() end }
    local t = telemetry.new({ namespace = namespace, persist = false })
    t.wrap(mod)
    t.start()
    mod.f()

    local md_path = tmpdir .. "/export_test.md"
    vim.cmd("RATelemetry export " .. md_path)
    local md_file = io.open(md_path, "r")
    H.ok(md_file ~= nil, "export writes a .md path as Markdown")
    local md_content = md_file:read("*a")
    md_file:close()
    H.ok(
      md_content:find("# runtime-analysis.nvim — telemetry", 1, true) ~= nil,
      "combined Markdown document, same shape as markdown_all()"
    )

    local json_path = tmpdir .. "/export_test.json"
    vim.cmd("RATelemetry export " .. json_path)
    local json_file = io.open(json_path, "r")
    H.ok(json_file ~= nil, "export writes a .json path as JSON (unchanged default behavior)")
    local json_content = json_file:read("*a")
    json_file:close()
    local ok_decode, decoded = pcall(vim.json.decode, json_content)
    H.eq(ok_decode, true, "the .json export is still valid JSON")
    H.ok(decoded.reports ~= nil, "...with the expected top-level shape")

    t.stop()
    t.unwrap()
  end

  -- -------------------------------------------------------------------------
  -- :RATelemetry export .pdf — routes through pdfport.nvim (optional
  -- dependency, soft-required). Stubs package.loaded["pdfport"] rather than
  -- depending on a real pdfport.nvim + pandoc install being present on the
  -- machine running the suite -- same pattern github_stats.nvim/
  -- documentation.nvim/markdown.nvim use for their own pdfport integrations.
  -- -------------------------------------------------------------------------
  do
    local namespace = ns("export_pdf")
    local mod = { f = function() end }
    local t = telemetry.new({ namespace = namespace, persist = false })
    t.wrap(mod)
    t.start()
    mod.f()

    local pdf_path = tmpdir .. "/export_test.pdf"

    -- No pdfport.nvim installed -> clear error, nothing written.
    package.loaded["pdfport"] = nil
    local notified
    local orig_vim_notify = vim.notify
    vim.notify = function(msg, level)
      notified = { msg = msg, level = level }
    end

    vim.cmd("RATelemetry export " .. pdf_path)
    H.ok(
      notified and notified.msg:find("export failed", 1, true) ~= nil,
      "no pdfport.nvim -> :RATelemetry export .pdf reports failure"
    )
    H.eq(io.open(pdf_path, "r"), nil, "no pdfport.nvim -> nothing written")

    -- pdfport.nvim installed, markdown producer available -> writes through.
    local create_opts
    package.loaded["pdfport"] = {
      can_create = function(kind)
        return kind == "markdown"
      end,
      create = function(opts)
        create_opts = opts
        -- Synchronous stub so the assertion below can run immediately after
        -- vim.cmd() returns, same as the real pdfport.create() would resolve
        -- eventually via its own async callback.
        opts.__callback({ status = "ok", path = opts.output })
      end,
    }
    notified = nil
    vim.cmd("RATelemetry export " .. pdf_path)
    H.ok(
      notified and notified.msg:find("wrote", 1, true) ~= nil,
      "pdfport.nvim available -> :RATelemetry export .pdf reports success"
    )
    H.eq(create_opts.from, "markdown", 'pdfport.create() gets from = "markdown"')
    H.eq(create_opts.output, pdf_path, "pdfport.create() gets the requested output path")
    H.ok(
      create_opts.text:find("# runtime-analysis.nvim — telemetry", 1, true) ~= nil,
      "pdfport.create() gets the same combined Markdown document the .md export writes"
    )

    vim.notify = orig_vim_notify
    package.loaded["pdfport"] = nil
    t.stop()
    t.unwrap()
  end

  -- -------------------------------------------------------------------------
  -- :RATelemetry open [ns] — forces a flush, then dispatches per
  -- report_style. "mdview" falls back to "kit" here since mdview is
  -- unavailable in this test run (see report_style resolution tests above).
  -- -------------------------------------------------------------------------
  do
    local namespace = ns("open")
    local mod = { f = function() end }
    local t = telemetry.new({ namespace = namespace, persist = false, dir = tmpdir })
    t.wrap(mod)
    t.start()
    mod.f()

    telemetry.setup({ report_style = "kit" })
    local ok = pcall(vim.cmd, "RATelemetry open " .. namespace)
    H.eq(ok, true, ":RATelemetry open <ns> does not error with report_style = kit")

    telemetry.setup({ report_style = "file" })
    ok = pcall(vim.cmd, "RATelemetry open " .. namespace)
    H.eq(ok, true, ":RATelemetry open <ns> does not error with report_style = file")
    local report_file = require("runtime-analysis.telemetry.report_file")
    local path = report_file.namespace_path(namespace, { dir = tmpdir })
    H.ok(io.open(path, "r") ~= nil, "report_style = file wrote the per-namespace report")

    telemetry.setup({ report_style = "mdview" })
    ok = pcall(vim.cmd, "RATelemetry open " .. namespace)
    H.eq(
      ok,
      true,
      "report_style = mdview falls back to the kit float without erroring when mdview is unavailable"
    )

    ok = pcall(vim.cmd, "RATelemetry open does-not-exist")
    H.eq(ok, true, "an unknown namespace warns rather than erroring")

    ok = pcall(vim.cmd, "RATelemetry open")
    H.eq(ok, true, "bare open (every instance, combined) does not error")

    telemetry.setup({ report_style = "auto" }) -- restore default for any later spec
    t.stop()
    t.unwrap()
  end

  do
    local completions = vim.fn.getcompletion("RATelemetry open ", "cmdline")
    H.eq(
      vim.tbl_contains(completions, "open"),
      false,
      "subcommands not repeated as a 2nd arg after open"
    )

    local first_token_completions = vim.fn.getcompletion("RATelemetry o", "cmdline")
    H.ok(vim.tbl_contains(first_token_completions, "open"), "open is offered as a subcommand")
  end

  -- -------------------------------------------------------------------------
  -- Options.info: free-form metadata (branch, version/release tag, …)
  -- bundled with the report -- the caller supplies it (e.g. via
  -- lib.nvim.git.info(dir)); this module never inspects a repo to guess it.
  -- -------------------------------------------------------------------------
  do
    local mod = { f = function() end }
    local t = telemetry.new({
      namespace = ns("info"),
      persist = false,
      info = { branch = "main", version = "v1.2.3" },
    })
    t.wrap(mod)
    t.start()
    mod.f()

    local rep = t.report()
    H.eq(rep.info.branch, "main", "report().info carries Options.info through")
    H.eq(rep.info.version, "v1.2.3", "...every field of it")

    local text = table.concat(t.lines(), "\n")
    H.ok(text:find("branch=main", 1, true) ~= nil, "lines() renders the info fields")
    H.ok(text:find("version=v1.2.3", 1, true) ~= nil, "...sorted, so key order is deterministic")

    local md = table.concat(t.markdown(), "\n")
    H.ok(md:find("branch=main", 1, true) ~= nil, "markdown() renders the same info line")

    t.stop()
    t.unwrap()
  end

  do
    local t = telemetry.new({ namespace = ns("info_absent"), persist = false })
    local rep = t.report()
    H.eq(next(rep.info), nil, "no Options.info given -> report().info is empty, not nil")
    H.eq(
      table.concat(t.lines(), "\n"):find("=", 1, true),
      nil,
      "lines() renders no info line at all when there is nothing to show"
    )
    t.unwrap()
  end

  -- info persists across a flush, and a newer session's info replaces an
  -- older one wholesale rather than merging field-by-field -- a branch
  -- switch between sessions should not leave a stale field from the first
  -- one sitting alongside the new ones.
  do
    local namespace = ns("info_persist")
    local mod = { f = function() end }

    local t1 = telemetry.new({
      namespace = namespace,
      persist = true,
      dir = tmpdir,
      info = { branch = "feature-x", version = "v1.0.0" },
    })
    t1.wrap(mod)
    t1.start()
    mod.f()
    t1.stop() -- flushes
    t1.unwrap()

    local on_disk = store.load(namespace, { dir = tmpdir })
    H.eq(on_disk.info.branch, "feature-x", "info reached disk")
    H.eq(on_disk.info.version, "v1.0.0", "...every field")

    local t2 = telemetry.new({
      namespace = namespace,
      persist = true,
      dir = tmpdir,
      info = { branch = "main" }, -- narrower table, different branch
    })
    H.eq(t2.report().info.branch, "main", "a fresh instance's info is visible immediately")
    t2.wrap(mod)
    t2.start()
    mod.f()
    t2.stop()
    t2.unwrap()

    local merged = store.load(namespace, { dir = tmpdir })
    H.eq(merged.info.branch, "main", "the newer session's info wins")
    H.eq(
      merged.info.version,
      nil,
      "...wholesale, not merged field-by-field -- the stale 'version' from the first session is gone, not carried over"
    )
  end

  -- reset() keeps Options.info available immediately, the same treatment
  -- the module-id map gets -- info is a property of this instance's
  -- configuration, not of the counts reset() clears.
  do
    local t = telemetry.new({
      namespace = ns("info_reset"),
      persist = true,
      dir = tmpdir,
      info = { branch = "main" },
    })
    t.reset()
    H.eq(
      t.report().info.branch,
      "main",
      "resolved_modules()-style: info survives reset() in memory"
    )
    t.flush()
    H.eq(
      store.load(t.namespace, { dir = tmpdir }).info.branch,
      "main",
      "...and is back on disk after the next flush, without re-specifying it"
    )
    t.unwrap()
  end

  -- -------------------------------------------------------------------------
  -- telemetry.auto(): the "instrument a whole plugin generically" convenience
  -- every auto-instrument-on-load caller needs, regardless of which plugin
  -- manager drives it -- new() + wrap()/wrap_loaded() + start() in one call.
  -- -------------------------------------------------------------------------
  do
    H.eq(
      telemetry.auto({ namespace = ns("auto_unloaded"), main = "totally_unloaded_plugin" }),
      nil,
      "nothing of main loaded yet -> nil, no instance created"
    )
  end

  do
    package.loaded["fakeauto"] = { facade = function() end }
    local inst =
      telemetry.auto({ namespace = ns("auto_shallow"), main = "fakeauto", persist = false })
    H.ok(inst ~= nil, "façade loaded -> an instance is returned")
    H.eq(inst.is_running(), true, "start() ran -- auto() leaves nothing half-wired")
    H.ok(vim.tbl_contains(inst.wrapped_keys(), "facade"), "shallow: only the façade's own keys")
    inst.stop()
    inst.unwrap()
    package.loaded["fakeauto"] = nil
  end

  do
    package.loaded["fakeauto"] = { facade = function() end }
    package.loaded["fakeauto.core"] = { a = function() end }
    package.loaded["fakeauto.@types"] = { noise = function() end }
    local inst = telemetry.auto({
      namespace = ns("auto_deep"),
      main = "fakeauto",
      deep = true,
      persist = false,
    })
    local keys = inst.wrapped_keys()
    H.ok(vim.tbl_contains(keys, "facade"), "deep: façade included")
    H.ok(vim.tbl_contains(keys, "core.a"), "deep: whole loaded subtree, not just the façade")
    H.eq(
      vim.tbl_contains(keys, "@types.noise"),
      false,
      "deep: @types excluded by the default module_filter"
    )
    inst.stop()
    inst.unwrap()
    for _, name in ipairs({ "fakeauto", "fakeauto.core", "fakeauto.@types" }) do
      package.loaded[name] = nil
    end
  end

  do
    -- lua/<main>/init.lua reachable as both "<main>" and "<main>.init" --
    -- gating the shallow path on the bare name alone would silently skip a
    -- plugin that happened to load via the ".init" form.
    package.loaded["fakeauto_init.init"] = { go = function() end }
    local inst =
      telemetry.auto({ namespace = ns("auto_dotinit"), main = "fakeauto_init", persist = false })
    H.ok(inst ~= nil, "package.loaded[main .. '.init'] resolves when [main] itself does not")
    H.ok(vim.tbl_contains(inst.wrapped_keys(), "go"), "its function got wrapped")
    inst.stop()
    inst.unwrap()
    package.loaded["fakeauto_init.init"] = nil
  end

  do
    package.loaded["fakeauto_opts"] = { f = function() end }
    local inst = telemetry.auto({
      namespace = ns("auto_opts"),
      main = "fakeauto_opts",
      profile_args = true,
      timing = true,
      persist = false,
    })
    package.loaded["fakeauto_opts"].f("x")
    H.eq(inst.report().modes.timing, true, "timing=true reached start()")
    H.ok(inst.report().entries[1].args ~= nil, "profile_args=true reached start()")
    inst.stop()
    inst.unwrap()
    package.loaded["fakeauto_opts"] = nil
  end

  -- -------------------------------------------------------------------------
  -- named/dated snapshots -- docs/ROADMAP.md §4.5
  -- -------------------------------------------------------------------------

  do
    H.eq(
      store.sanitize_snapshot_name("my name"),
      "my_name",
      "snapshot name sanitized the same way a namespace is"
    )
    H.eq(store.sanitize_snapshot_name("../evil"), "_evil", "cannot escape the snapshots directory")
    H.eq(store.sanitize_snapshot_name(""), "unnamed", "empty name falls back")
  end

  -- store-level round trip, no telemetry instance involved at all
  do
    local namespace = ns("snap_store")
    local data = store.empty()
    data.functions.f = { calls = 5 }

    H.eq(#store.list_snapshots(namespace, { dir = tmpdir }), 0, "nothing saved yet")
    H.ok(store.save_snapshot(namespace, "first", data, { dir = tmpdir }), "save_snapshot ok")

    local list = store.list_snapshots(namespace, { dir = tmpdir })
    H.eq(#list, 1, "one snapshot listed")
    H.eq(list[1].name, "first", "sanitized name carried through")

    local loaded = store.load_snapshot(namespace, "first", { dir = tmpdir })
    H.eq(loaded.functions.f.calls, 5, "snapshot data round-trips")

    H.eq(
      store.load_snapshot(namespace, "does-not-exist", { dir = tmpdir }),
      nil,
      "unknown snapshot: nil, not an error"
    )

    H.ok(store.delete_snapshot(namespace, "first", { dir = tmpdir }), "delete_snapshot ok")
    H.eq(#store.list_snapshots(namespace, { dir = tmpdir }), 0, "gone after delete")
  end

  -- retention / eviction -- store-level, count-only assertions: mtime
  -- granularity is one second, so five snapshots saved back-to-back in a
  -- tight loop can tie, and *which* two are oldest among a tie is not this
  -- test's business -- only that eviction keeps exactly `keep` of them.
  do
    local namespace = ns("snap_evict")
    for i = 1, 5 do
      store.save_snapshot(namespace, "s" .. i, store.empty(), { dir = tmpdir })
    end
    H.eq(#store.list_snapshots(namespace, { dir = tmpdir }), 5, "all five present before eviction")

    local evicted = store.evict_old_snapshots(namespace, 3, { dir = tmpdir })
    H.eq(evicted, 2, "oldest two evicted, three kept")
    H.eq(#store.list_snapshots(namespace, { dir = tmpdir }), 3, "three remain")

    H.eq(
      store.evict_old_snapshots(namespace, 0, { dir = tmpdir }),
      0,
      "keep<=0 means do not evict, not delete everything"
    )
    H.eq(#store.list_snapshots(namespace, { dir = tmpdir }), 3, "...confirmed untouched")
  end

  -- telemetry.snapshot / list_snapshots / load_snapshot -- module-level API
  do
    local namespace = ns("snap_api_none")
    H.eq(
      telemetry.snapshot(namespace),
      nil,
      "nothing to snapshot: no live instance and nothing ever persisted"
    )
  end

  do
    local namespace = ns("snap_api_live")
    local mod = { f = function() end }
    local inst = telemetry.new({ namespace = namespace, dir = tmpdir, persist = true })
    inst.wrap(mod, "mod", { module_id = "a" })
    inst.start()
    mod.f()
    mod.f()
    -- Deliberately not flushed yet -- M.snapshot must flush itself, and this
    -- is the property this block actually checks.

    local saved_name = telemetry.snapshot(namespace, "before release")
    H.eq(
      saved_name,
      "before_release",
      "returned name sanitized the same way store.sanitize_snapshot_name does"
    )

    local snap = telemetry.load_snapshot(namespace, saved_name)
    H.eq(
      snap.functions["mod.f"].calls,
      2,
      "snapshot captured pending calls too, via the forced flush"
    )

    local list = telemetry.list_snapshots(namespace)
    H.eq(#list, 1, "listed via the module-level API too")
    H.eq(list[1].name, "before_release", "same name")

    local auto_name = telemetry.snapshot(namespace)
    H.ok(
      auto_name ~= nil and auto_name:match("^%d%d%d%d%-%d%d%-%d%dT") ~= nil,
      "no name given: falls back to a timestamp"
    )

    inst.stop()
  end

  -- retention wired through the module-level API, not just store.lua's own
  do
    local namespace = ns("snap_api_retention")
    local inst = telemetry.new({ namespace = namespace, dir = tmpdir, persist = true })
    inst.start()

    local saved_retention = telemetry.SNAPSHOT_RETENTION
    telemetry.SNAPSHOT_RETENTION = 3
    for i = 1, 5 do
      telemetry.snapshot(namespace, "s" .. i)
    end
    H.eq(#telemetry.list_snapshots(namespace), 3, "M.snapshot evicts down to SNAPSHOT_RETENTION")
    telemetry.SNAPSHOT_RETENTION = saved_retention

    inst.stop()
  end

  -- opts.snapshot_retention: a per-instance override, confirmed with the
  -- user 2026-08-10 -- SNAPSHOT_RETENTION alone was a hardcoded module
  -- constant with no way to configure it per namespace.
  do
    local namespace = ns("snap_api_retention_override")
    -- Global left at its real default deliberately, to prove the override
    -- actually wins rather than merely matching a global also set to 2.
    local inst = telemetry.new({
      namespace = namespace,
      dir = tmpdir,
      persist = true,
      snapshot_retention = 2,
    })
    inst.start()
    for i = 1, 5 do
      telemetry.snapshot(namespace, "s" .. i)
    end
    H.eq(
      #telemetry.list_snapshots(namespace),
      2,
      "opts.snapshot_retention overrides the global SNAPSHOT_RETENTION default"
    )
    inst.stop()
  end

  -- No live instance at all: M.snapshot falls back to the global
  -- SNAPSHOT_RETENTION, exactly the pre-override behavior -- a namespace
  -- with nothing wrapped can still be snapshotted (from data another
  -- process already persisted), and it has no instance to carry an
  -- override on.
  do
    local namespace = ns("snap_api_retention_no_instance")
    local data = store.empty()
    data.functions.f = { calls = 1 }
    store.save(namespace, data, { dir = tmpdir })

    local saved_retention = telemetry.SNAPSHOT_RETENTION
    telemetry.SNAPSHOT_RETENTION = 2
    -- No live instance, so `M.snapshot` reads/writes via DEFAULT_CACHE_DIR
    -- (the real one) rather than `tmpdir` -- clear it after, same
    -- self-healing pattern the real end-to-end block above already uses.
    local real_cache_dir = vim.fn.stdpath("cache") .. "/runtime-analysis.nvim/cache"
    store.save(namespace, data, { dir = real_cache_dir })
    for i = 1, 4 do
      telemetry.snapshot(namespace, "n" .. i)
    end
    H.eq(
      #telemetry.list_snapshots(namespace, { dir = real_cache_dir }),
      2,
      "no live instance: falls back to the global SNAPSHOT_RETENTION"
    )
    telemetry.SNAPSHOT_RETENTION = saved_retention
    store.clear(namespace, { dir = real_cache_dir })
    for i = 1, 4 do
      store.delete_snapshot(namespace, "n" .. i, { dir = real_cache_dir })
    end
  end

  vim.fn.delete(tmpdir, "rf")
end
