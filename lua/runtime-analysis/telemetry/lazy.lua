---@module 'runtime-analysis.telemetry.lazy'
--- lazy.nvim-specific auto-instrumentation: the one mechanism only lazy.nvim
--- can provide (a per-plugin "just loaded" event) wrapped around `telemetry.
--- auto()`, so a caller never touches `lazy.core.*` itself. The one plugin-
--- manager adapter this module ships — packer.nvim has no per-plugin load
--- event of its own to hook, and vim-plug has no lazy-loading concept at
--- all, so there is nothing equivalent to adapt for either. If lazy.nvim is
--- not present, `setup()` is a no-op.
---
---   require("runtime-analysis.telemetry.lazy").setup({
---     plugins = {
---       ["StefanBartl/markdown.nvim"] = { namespace = "markdown.nvim", deep = true },
---       -- ... one entry per plugin worth instrumenting, keyed by repo ...
---     },
---     lib_nvim = { profile_args = false },  -- false/nil to skip entirely
---   })
---
--- Which plugins get instrumented, and with what settings, is entirely the
--- caller's own policy — this module only walks the list it is handed and
--- wires the mechanism up. `lib_nvim` is separate from `plugins` because
--- instrumenting `require("lib")`'s own aggregate goes through lib.nvim's
--- own `lib.strategies.telemetry_wrap` (metatable-hidden keys, `wrap_loaded`
--- would reach every internal helper), not `telemetry.auto()`.
---
--- CATCH-UP, NOT JUST THE EVENT
--- `User LazyLoad` fires once per plugin the moment its OWN `config()`
--- finishes. A `lazy=false` dependency of the caller's own plugin (lib.nvim,
--- typically) fires that event DURING `lazy.setup()`, quite possibly
--- *before* the caller's own `config()` — the one place this `setup()` can
--- realistically be called from — ever runs. Registering only the autocmd
--- would silently miss it. So `setup()` does a one-time scan of everything
--- in `plugins` (and lib.nvim, via `lib_nvim`) already loaded RIGHT NOW,
--- then registers the autocmd for everything after — no "must run before
--- lazy.setup()" ordering requirement on the caller, unlike hand-rolling
--- this same mechanism directly (see lib.nvim's own `config/telemetry.lua`,
--- before this module existed, for what that ordering requirement cost).

local M = {}

---The `opts` handed to the most recent `M.setup()` call -- kept around so
---`M.candidates()` (in turn, `:RATelemetrySetupAll`/`:RATelemetrySetupAllFull`,
---telemetry/setup_all.lua) can reuse the exact same plugin policy instead of
---a caller having to pass the list a second time. `nil` until `M.setup()`
---has actually run at least once this session.
---@type RA.Telemetry.LazyOpts?
local configured

---@internal
---@param namespace string
---@param main string
---@param settings table
---@return RA.Telemetry.Instance|nil
local function auto_wrap(namespace, main, settings)
  return require("runtime-analysis.telemetry").auto({
    namespace = namespace,
    main = main,
    deep = settings.deep,
    profile_args = settings.profile_args,
    timing = settings.timing,
    persist = settings.persist,
    dir = settings.dir,
  })
end

---@internal
---@param lib_opts table
local function wrap_lib_nvim(lib_opts)
  local ok, telemetry_wrap = pcall(require, "lib.strategies.telemetry_wrap")
  if not ok then
    return
  end
  telemetry_wrap.setup({
    profile_args = lib_opts.profile_args,
    timing = lib_opts.timing,
    persist = lib_opts.persist,
    dir = lib_opts.dir,
  })
end

---@param opts RA.Telemetry.LazyOpts
function M.setup(opts)
  configured = opts

  local ok_config, lazy_config = pcall(require, "lazy.core.config")
  if not ok_config then
    return
  end
  local ok_loader, lazy_loader = pcall(require, "lazy.core.loader")
  if not ok_loader then
    return
  end

  ---@type table<string, boolean>
  local started = {}

  if opts.lib_nvim then
    started["lib.nvim"] = true
    wrap_lib_nvim(opts.lib_nvim)
  end

  ---@param plugin_name string
  local function try_wrap(plugin_name)
    if started[plugin_name] then
      return
    end
    local plugin = lazy_config.plugins[plugin_name]
    if not plugin then
      return
    end
    -- `plugin[1]` is the repo as declared in the spec -- anything without
    -- one (a bare `dir = ...` entry) cannot match a `plugins` key.
    local repo = type(plugin[1]) == "string" and plugin[1] or nil
    local settings = repo and opts.plugins[repo]
    if not settings then
      return
    end
    local main = lazy_loader.get_main(plugin)
    if not main then
      return
    end
    -- auto() itself returns nil when nothing of `main` is loaded yet, so a
    -- plugin the catch-up scan visits too early is simply left for the
    -- autocmd below to pick up once it actually loads.
    if auto_wrap(settings.namespace, main, settings) then
      started[plugin_name] = true
    end
  end

  -- Catch-up: `lazy.core.config.plugins` is fully populated by the time any
  -- spec's own config() runs (spec resolution finishes before any plugin is
  -- loaded), regardless of load order -- so this sees every plugin, checks
  -- what is already loaded, and wraps it now rather than never.
  for plugin_name in pairs(lazy_config.plugins) do
    try_wrap(plugin_name)
  end

  vim.api.nvim_create_autocmd("User", {
    pattern = "LazyLoad",
    group = vim.api.nvim_create_augroup("runtime_analysis_telemetry_lazyload", { clear = true }),
    desc = "runtime-analysis.telemetry: wrap+start an instance for each plugin as it loads",
    callback = function(args)
      if type(args.data) == "string" then
        try_wrap(args.data)
      end
    end,
  })
end

---The `opts` the most recent `M.setup()` call received, unchanged --
---`nil` before `M.setup()` has run this session.
---@return RA.Telemetry.LazyOpts?
function M.configured()
  return configured
end

---Every configured plugin (`M.setup()`'s own `opts.plugins`, keyed by repo)
---that lazy.nvim can currently resolve to a loaded root module -- the list
---`:RATelemetrySetupAll`/`:RATelemetrySetupAllFull` (telemetry/setup_all.lua)
---acts on.
---
---Deliberately independent of `try_wrap`'s own `started` bookkeeping above:
---that set exists so the catch-up scan and the `LazyLoad` autocmd never
---double-wrap the same plugin, which is irrelevant here -- a caller of this
---function always intends to act again (reset, re-wrap, restart), on
---purpose, regardless of whether the automatic mechanism already wrapped
---this plugin once this session.
---
---Empty when lazy.nvim is not the plugin manager, `M.setup()` has not run
---yet, or `opts.plugins` was empty -- the same soft-dependency posture
---`M.setup()` itself already has.
---@return RA.Telemetry.SetupAllCandidate[]
function M.candidates()
  if not configured or not configured.plugins or next(configured.plugins) == nil then
    return {}
  end

  local ok_config, lazy_config = pcall(require, "lazy.core.config")
  if not ok_config then
    return {}
  end
  local ok_loader, lazy_loader = pcall(require, "lazy.core.loader")
  if not ok_loader then
    return {}
  end

  local telemetry = require("runtime-analysis.telemetry")

  ---@type RA.Telemetry.SetupAllCandidate[]
  local out = {}
  for plugin_name, plugin in pairs(lazy_config.plugins) do
    local repo = type(plugin[1]) == "string" and plugin[1] or nil
    local settings = repo and configured.plugins[repo]
    if settings then
      local main = lazy_loader.get_main(plugin)
      if main and telemetry.module_loaded(main) then
        out[#out + 1] = {
          repo = repo,
          namespace = settings.namespace,
          main = main,
          settings = settings,
        }
      end
    end
  end

  -- Stable order (by namespace) so a progress callback and a closing report
  -- read the same way run to run, rather than following `pairs()`'s own
  -- unspecified iteration order.
  table.sort(out, function(a, b)
    return a.namespace < b.namespace
  end)
  return out
end

return M
