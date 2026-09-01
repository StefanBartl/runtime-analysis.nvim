-- Test code: when something here comes back nil -- a `pcall(require, ...)`,
-- a fixture read, a uv handle -- this file must crash and name it. The nil
-- guards LuaLS asks for below would hide the very failure it exists to report.
---@diagnostic disable: need-check-nil
-- TESTS/setup_all_spec.lua — runtime-analysis.telemetry.lazy's
-- candidates()/configured(), and runtime-analysis.telemetry.setup_all's
-- backup + reset + re-wrap + restart mechanism
-- (:RATelemetrySetupAll/:RATelemetrySetupAllFull's own engine).
--
-- Same stubbing approach lazy_spec.lua already uses: real lazy.nvim is not
-- on this test run's rtp, so `lazy.core.config`/`lazy.core.loader` are
-- faked directly via `package.loaded`.

return function(H)
  local eq, ok = H.eq, H.ok

  local lazy_adapter = require("runtime-analysis.telemetry.lazy")
  local telemetry = require("runtime-analysis.telemetry")
  local setup_all = require("runtime-analysis.telemetry.setup_all")
  local store = require("runtime-analysis.telemetry.store")

  local tmpdir = vim.fn.tempname() .. "-setup-all"
  vim.fn.mkdir(tmpdir, "p")
  -- Deliberately NOT pre-created -- proves the backup step creates it,
  -- the same "create the folder if it does not exist yet" requirement
  -- `:RATelemetrySetupAll`'s own prompt handling has to satisfy.
  local backup_dir = tmpdir .. "/backups"

  local seq = 0
  local function ns(name)
    seq = seq + 1
    return ("spec.setup_all.%s.%d"):format(name, seq)
  end

  -- `f` stands in for any wrapped function, and the calls below hand it
  -- one and three arguments to check argument fingerprinting -- so it takes
  -- what a stand-in has to take.
  package.loaded["fakesetupall_loaded"] = { f = function(...) end }
  package.loaded["fakesetupall_notloaded"] = nil

  local plugin_loaded = { "someorg/setupall-loaded.nvim" }
  local plugin_notloaded = { "someorg/setupall-notloaded.nvim" }

  package.loaded["lazy.core.config"] = {
    plugins = { loaded_p = plugin_loaded, notloaded_p = plugin_notloaded },
  }
  package.loaded["lazy.core.loader"] = {
    get_main = function(plugin)
      if plugin == plugin_loaded then
        return "fakesetupall_loaded"
      elseif plugin == plugin_notloaded then
        return "fakesetupall_notloaded"
      end
      return nil
    end,
  }

  local ns_loaded = ns("loaded")
  local ns_notloaded = ns("notloaded")

  -- setup() itself catch-up-wraps ns_loaded immediately (fakesetupall_loaded
  -- is already in package.loaded) -- exactly the live-instance-already-
  -- exists case setup_all.run() has to reset+re-wrap rather than duplicate.
  lazy_adapter.setup({
    plugins = {
      ["someorg/setupall-loaded.nvim"] = {
        namespace = ns_loaded,
        deep = false,
        profile_args = false,
        timing = false,
        persist = true,
        dir = tmpdir,
      },
      ["someorg/setupall-notloaded.nvim"] = { namespace = ns_notloaded, persist = false },
    },
    lib_nvim = false,
  })

  -- --------------------------------------------------------- candidates()
  do
    local candidates = lazy_adapter.candidates()
    local by_ns = {}
    for _, c in ipairs(candidates) do
      by_ns[c.namespace] = c
    end
    ok(by_ns[ns_loaded] ~= nil, "candidates(): a configured, currently-loaded plugin is included")
    eq(by_ns[ns_notloaded], nil, "candidates(): a configured but NOT-loaded plugin is excluded")
    if by_ns[ns_loaded] then
      eq(
        by_ns[ns_loaded].main,
        "fakesetupall_loaded",
        "candidates(): resolves the real main module"
      )
      eq(
        by_ns[ns_loaded].repo,
        "someorg/setupall-loaded.nvim",
        "candidates(): carries the repo key back"
      )
    end
  end

  eq(
    lazy_adapter.configured() ~= nil and lazy_adapter.configured().plugins ~= nil,
    true,
    "configured(): returns the opts the most recent setup() call received"
  )

  -- --------------------------------------- setup_all.run(): had_data=false
  -- Nothing persisted for ns_loaded yet (the catch-up-scan instance has
  -- never flushed) -- a plain run must not prompt for or write a backup.
  do
    local results = setup_all.run({ backup_dir = backup_dir })
    local mine
    for _, r in ipairs(results) do
      if r.namespace == ns_loaded then
        mine = r
      end
    end
    ok(mine ~= nil, "run(): ns_loaded is in the results")
    if mine then
      eq(mine.had_data, false, "run(): no persisted data yet -- had_data is false")
      eq(mine.backed_up, nil, "run(): ...so nothing was backed up")
    end
    eq(vim.fn.isdirectory(backup_dir), 0, "run(): backup_dir is not created when nothing needed it")

    local inst = telemetry.get(ns_loaded)
    ok(inst ~= nil, "run(): the existing live instance is reused, not duplicated")
    ok(inst.is_running(), "run(): the instance is running after setup_all")
  end

  -- ------------------------------------- generate real data, then re-run
  do
    package.loaded["fakesetupall_loaded"].f(1, 2, 3)
    package.loaded["fakesetupall_loaded"].f("x")
    local inst = telemetry.get(ns_loaded)
    inst.flush()

    local before_reset = store.load(ns_loaded, { dir = tmpdir })
    eq(before_reset.functions.f.calls, 2, "sanity: two real calls landed on disk before this run")

    local results = setup_all.run({ backup_dir = backup_dir })
    local mine
    for _, r in ipairs(results) do
      if r.namespace == ns_loaded then
        mine = r
      end
    end
    ok(mine ~= nil, "run(): ns_loaded is in the results again")
    if mine then
      eq(mine.had_data, true, "run(): persisted data existed this time -- had_data is true")
      ok(
        type(mine.backed_up) == "string" and mine.backed_up:find(backup_dir, 1, true) == 1,
        "run(): backed_up names a real path inside backup_dir"
      )
    end

    eq(
      vim.fn.isdirectory(backup_dir),
      1,
      "run(): backup_dir was created (it did not exist before this run)"
    )

    if mine and mine.backed_up then
      local fd = assert(io.open(mine.backed_up, "r"))
      local body = fd:read("*a")
      fd:close()
      local decoded = vim.json.decode(body)
      eq(decoded.namespace, ns_loaded, "backup file: records the right namespace")
      eq(decoded.data.functions.f.calls, 2, "backup file: carries the real pre-reset call count")
    end

    local after_reset = store.load_readonly(ns_loaded, { dir = tmpdir })
    eq(after_reset, nil, "run(): reset actually cleared the persisted aggregate on disk")
  end

  -- --------------------------------------------------- full forces args on
  -- ns_loaded's own configured policy is profile_args = false (set above);
  -- a plain run must not fingerprint arguments, `full = true` must.
  do
    setup_all.run({ full = false })
    package.loaded["fakesetupall_loaded"].f("plain-mode-call")
    telemetry.get(ns_loaded).flush()
    local data = store.load(ns_loaded, { dir = tmpdir })
    eq(
      data.functions.f.args,
      nil,
      "run({full=false}): respects the plugin's own profile_args=false"
    )

    setup_all.run({ full = true })
    package.loaded["fakesetupall_loaded"].f("full-mode-call")
    telemetry.get(ns_loaded).flush()
    data = store.load(ns_loaded, { dir = tmpdir })
    ok(
      data.functions.f.args ~= nil,
      "run({full=true}): forces argument profiling on regardless of the plugin's own policy"
    )
  end

  -- ------------------------------------------------------------- teardown
  local inst = telemetry.get(ns_loaded)
  if inst then
    inst.stop()
    inst.unwrap()
    store.clear(ns_loaded, { dir = tmpdir })
  end
  package.loaded["fakesetupall_loaded"] = nil
  package.loaded["lazy.core.config"] = nil
  package.loaded["lazy.core.loader"] = nil
  os.execute(('rm -rf "%s"'):format(tmpdir))
end
