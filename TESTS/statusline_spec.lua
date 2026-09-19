-- TESTS/statusline_spec.lua — `runtime-analysis.statusline`, the traffic
-- light a statusline plugin calls.
--
-- These assertions used to live in ui.nvim, against a fake
-- `runtime-analysis.telemetry`. The component moved here (cross-feature
-- report, finding E) and the tests came with it. The telemetry facade is
-- still stubbed — this spec is about how the numbers are *interpreted*,
-- and staging a real errored-and-slow instance would test the telemetry
-- layer instead, which its own specs already do.

return function(H)
  local statusline = require("runtime-analysis.statusline")
  local telemetry = require("runtime-analysis.telemetry")

  local RED = " \240\159\148\180 "
  local YELLOW = " \240\159\159\161 "
  local GREEN = " \240\159\159\162 "

  local real = {
    known_namespaces = telemetry.known_namespaces,
    get = telemetry.get,
    load = telemetry.load,
  }

  --- Stub the facade with one namespace whose live instance reports
  --- `entries`.
  ---@param entries table[]
  local function with_live(entries)
    statusline.invalidate()
    telemetry.known_namespaces = function()
      return { "spec" }
    end
    telemetry.get = function()
      return {
        report = function()
          return { entries = entries }
        end,
      }
    end
  end

  local function restore()
    telemetry.known_namespaces = real.known_namespaces
    telemetry.get = real.get
    telemetry.load = real.load
    statusline.invalidate()
  end

  -- Nothing to watch ---------------------------------------------------------
  statusline.invalidate()
  telemetry.known_namespaces = function()
    return {}
  end
  H.eq(statusline.status(), "", "no known namespaces renders empty, not a green light")

  -- Green --------------------------------------------------------------------
  with_live({ { errors = 0, mean_ms = 1 } })
  H.eq(statusline.status(), GREEN, "no errors and nothing slow is green")

  -- Yellow -------------------------------------------------------------------
  with_live({ { errors = 0, mean_ms = 500 } })
  H.eq(statusline.status(), YELLOW, "a slow function with no errors is yellow")

  -- Red ----------------------------------------------------------------------
  with_live({ { errors = 1, mean_ms = 1 } })
  H.eq(statusline.status(), RED, "an error is red")

  -- Red wins over yellow: an error is the more important signal.
  with_live({ { errors = 1, mean_ms = 500 } })
  H.eq(statusline.status(), RED, "an error outranks slowness")

  -- One bad entry among many is enough to colour the whole light.
  with_live({
    { errors = 0, mean_ms = 1 },
    { errors = 0, mean_ms = 1 },
    { errors = 2, mean_ms = 1 },
  })
  H.eq(statusline.status(), RED, "one errored entry among healthy ones still shows red")

  -- The threshold ------------------------------------------------------------
  with_live({ { errors = 0, mean_ms = 60 } })
  H.eq(statusline.status(), YELLOW, "60ms is over the 50ms default")
  with_live({ { errors = 0, mean_ms = 60 } })
  H.eq(
    statusline.status({ slow_mean_ms = 200 }),
    GREEN,
    "...and under a caller's own higher threshold"
  )

  -- A missing mean (a function with no timing yet) must not be read as slow.
  with_live({ { errors = 0, mean_ms = nil } })
  H.eq(statusline.status(), GREEN, "an entry with no timing data is not slow")

  -- Caching (PERF-93) ---------------------------------------------------------
  -- A statusline redraws on nearly every event; the whole computed status,
  -- including the namespace scan, must be cached, not recomputed every call.
  do
    with_live({ { errors = 0, mean_ms = 1 } })
    local scans = 0
    local underlying_known_namespaces = telemetry.known_namespaces
    telemetry.known_namespaces = function(...)
      scans = scans + 1
      return underlying_known_namespaces(...)
    end
    H.eq(statusline.status(), GREEN, "cache: first call computes fresh")
    H.eq(scans, 1, "cache: first call actually scanned for namespaces")

    -- Same stub, same slow_ms: a second call within the TTL must be served
    -- from the cache, not scan again -- even though the underlying data
    -- changed (an error appeared), the cached answer still wins.
    telemetry.get = function()
      return {
        report = function()
          return { entries = { { errors = 1, mean_ms = 1 } } }
        end,
      }
    end
    H.eq(statusline.status(), GREEN, "cache: a second call within the TTL reuses the cached value")
    H.eq(scans, 1, "cache: ...and never re-scanned for namespaces")

    -- invalidate() drops the cache: the same call now reflects the change.
    statusline.invalidate()
    H.eq(statusline.status(), RED, "cache: invalidate() forces a fresh computation")
    H.eq(scans, 2, "cache: ...which scans for namespaces again")
  end

  -- Degradation --------------------------------------------------------------
  statusline.invalidate()
  telemetry.known_namespaces = function()
    error("spec: telemetry exploded")
  end
  H.eq(statusline.status(), "", "a throwing facade renders empty rather than raising")

  with_live({})
  telemetry.get = function()
    error("spec: get exploded")
  end
  telemetry.load = function()
    error("spec: load exploded")
  end
  H.eq(statusline.status(), GREEN, "a namespace that cannot be read contributes nothing")

  restore()

  -- The lualine alias --------------------------------------------------------
  H.eq(type(statusline.lualine_component), "function", "lualine_component is callable")
  H.eq(type(statusline.lualine_component()), "string", "...and returns a string")
end
