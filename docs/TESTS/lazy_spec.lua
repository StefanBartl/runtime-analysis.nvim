-- docs/TESTS/lazy_spec.lua — runtime-analysis.telemetry.lazy
--
-- The one plugin-manager adapter this module ships. Since real lazy.nvim is
-- not on this test run's runtime path, `lazy.core.config`/`lazy.core.loader`
-- are stubbed here rather than faked as real lazy.nvim internals -- this
-- exercises the adapter's own logic (catch-up scan, the ongoing autocmd,
-- per-plugin policy dispatch, dedup), not lazy.nvim's.

return function(H)
  local lazy_adapter = require("runtime-analysis.telemetry.lazy")

  -- Nothing stubbed yet -- setup() must be a safe no-op, not an error, when
  -- lazy.nvim genuinely is not the caller's plugin manager.
  do
    local ok = pcall(lazy_adapter.setup, { plugins = {} })
    H.eq(ok, true, "setup() does not error when lazy.core.config is unavailable")
  end

  local seq = 0
  local function ns(name)
    seq = seq + 1
    return ("spec.lazy.%s.%d"):format(name, seq)
  end

  -- Two fake plugins: "early" is already loaded (simulating a lazy=false
  -- dependency whose LazyLoad fired before this adapter's own setup() could
  -- run), "late" is not loaded yet, "unwanted" is loaded but never opted
  -- into `opts.plugins` at all.
  package.loaded["fakelazy_early"] = { f = function() end }

  local plugin_early = { "someorg/early.nvim" }
  local plugin_late = { "someorg/late.nvim" }
  local plugin_unwanted = { "someorg/unwanted.nvim" }

  package.loaded["lazy.core.config"] = {
    plugins = {
      early = plugin_early,
      late = plugin_late,
      unwanted = plugin_unwanted,
    },
  }
  package.loaded["lazy.core.loader"] = {
    get_main = function(plugin)
      if plugin == plugin_early then
        return "fakelazy_early"
      elseif plugin == plugin_late then
        return "fakelazy_late"
      end
      return nil
    end,
  }

  local ns_early = ns("early")
  local ns_late = ns("late")

  lazy_adapter.setup({
    plugins = {
      ["someorg/early.nvim"] = { namespace = ns_early, persist = false },
      ["someorg/late.nvim"] = { namespace = ns_late, persist = false },
    },
    lib_nvim = false,
  })

  local telemetry = require("runtime-analysis.telemetry")
  H.ok(telemetry.get(ns_early) ~= nil, "catch-up scan wraps a plugin already loaded")
  H.eq(telemetry.get(ns_late), nil, "a not-yet-loaded plugin is NOT wrapped by the catch-up scan")

  -- "late" now actually loads; fire the event the catch-up scan could not
  -- have seen yet.
  package.loaded["fakelazy_late"] = { g = function() end }
  vim.api.nvim_exec_autocmds("User", { pattern = "LazyLoad", data = "late" })
  H.ok(telemetry.get(ns_late) ~= nil, "the autocmd wraps a plugin once it actually loads")

  -- Re-firing the same event must not create a second live instance for the
  -- same namespace -- exactly the "two instances, one cache file" trap the
  -- original hand-rolled version guarded against with its own dedup set.
  local before = #telemetry.instances()
  vim.api.nvim_exec_autocmds("User", { pattern = "LazyLoad", data = "late" })
  H.eq(
    #telemetry.instances(),
    before,
    "re-firing LazyLoad for an already-started plugin is a no-op"
  )

  -- An unrecognized plugin_name (not in opts.plugins) loading is simply
  -- ignored, not an error.
  local ok_unwanted =
    pcall(vim.api.nvim_exec_autocmds, "User", { pattern = "LazyLoad", data = "unwanted" })
  H.eq(ok_unwanted, true, "a plugin never opted into `plugins` does not error")
  H.eq(telemetry.get("someorg/unwanted.nvim"), nil, "...and gets no instance")

  -- lib_nvim: soft dependency, must not error whether or not lib.nvim's
  -- lib.strategies.telemetry_wrap is actually reachable from this repo's
  -- test run.
  do
    local ok = pcall(lazy_adapter.setup, {
      plugins = {},
      lib_nvim = { profile_args = false, persist = false },
    })
    H.eq(ok, true, "lib_nvim wiring does not error regardless of lib.nvim's presence")
  end

  for _, inst in ipairs(telemetry.instances()) do
    if inst.namespace == ns_early or inst.namespace == ns_late then
      inst.stop()
      inst.unwrap()
    end
  end
  for _, name in ipairs({ "fakelazy_early", "fakelazy_late" }) do
    package.loaded[name] = nil
  end
  package.loaded["lazy.core.config"] = nil
  package.loaded["lazy.core.loader"] = nil
end
