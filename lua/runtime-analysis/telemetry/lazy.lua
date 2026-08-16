---@module 'runtime-analysis.telemetry.lazy'
--- lazy.nvim-specific auto-instrumentation: the one mechanism only lazy.nvim
--- can provide (a per-plugin "just loaded" event) wrapped around `telemetry.
--- auto()`, so a caller never touches `lazy.core.*` itself. The one plugin-
--- manager adapter this module ships — packer.nvim has no per-plugin load
--- event of its own to hook, and vim-plug has no lazy-loading concept at
--- all, so there is nothing equivalent to adapt for either. If lazy.nvim is
--- not present, the `plugins` half of `setup()` is a no-op (`extra` is not —
--- see below).
---
---   require("runtime-analysis.telemetry.lazy").setup({
---     plugins = {
---       ["StefanBartl/markdown.nvim"] = { namespace = "markdown.nvim", deep = true },
---       -- ... one entry per plugin worth instrumenting, keyed by repo ...
---     },
---     lib_nvim = { profile_args = false },  -- false/nil to skip entirely
---     extra = {
---       -- the reader's OWN config, which no plugin manager can resolve
---       { namespace = "nvim-config", mains = { "config", "bindings", "lsp" } },
---     },
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
---
--- `extra`: TARGETS NO PLUGIN MANAGER CAN SEE
--- `plugins` above can only ever describe things lazy.nvim resolves. The
--- reader's own Neovim config is not one of them — it has no repo, no spec,
--- and usually several unrelated root prefixes rather than one `main` — yet
--- it is often the single most interesting Lua tree in the session, and the
--- one whose dead code nobody else will ever report on. `extra` is that
--- target stated outright by the caller (see `RA.Telemetry.ExtraTarget`).
---
--- Two things follow, both deliberate:
---   * It does not touch `lazy.core.*` at all, so it works under any plugin
---     manager, or none. The lazy.nvim guard below covers only `plugins`.
---   * It is wrapped at VimEnter by default, NOT during `setup()`. A config's
---     own modules are mostly not loaded yet while `runtime-analysis.setup()`
---     runs (that call sits inside `lazy.setup()`, before the config's later
---     phases require anything), and `wrap_loaded()` only ever sees what is
---     already in `package.loaded`. Wrapping at `setup()` time would silently
---     produce a nearly empty namespace — the failure this default exists to
---     prevent. `wrap_at = "setup"|"manual"` overrides it per target.

local notify = require("lib.nvim.notify").create("[runtime-analysis.telemetry]")
local autocmd = require("lib.nvim.autocmd")
local config_validate = require("runtime-analysis.config.validate")

-- The exact fields each of `RA.Telemetry.LazyOpts`, `LazyPluginOpts` and
-- `ExtraTarget` accepts -- see `validate_opts` below, called once at the top
-- of `M.setup()`.
local KNOWN_LAZY_OPTS = { "plugins", "lib_nvim", "extra" }
local KNOWN_PLUGIN_OPTS = { "namespace", "deep", "profile_args", "timing", "persist", "dir" }
local KNOWN_EXTRA_OPTS =
  { "namespace", "mains", "deep", "profile_args", "timing", "persist", "dir", "wrap_at" }
local KNOWN_LIB_NVIM_OPTS = { "profile_args", "timing", "persist", "dir" }

---Unknown-key validation for `opts` and everything nested inside it that has
---its own fixed field set -- `opts.plugins` and `opts.extra` are keyed/
---indexed collections of such tables, not fixed-schema themselves, so only
---their *entries* are checked, never the collection keys/indices.
---@internal
---@param opts RA.Telemetry.LazyOpts
local function validate_opts(opts)
  config_validate.check(opts, KNOWN_LAZY_OPTS, "runtime-analysis.telemetry.lazy.setup()", notify)

  if type(opts.lib_nvim) == "table" then
    config_validate.check(
      opts.lib_nvim,
      KNOWN_LIB_NVIM_OPTS,
      "runtime-analysis.telemetry.lazy.setup() opts.lib_nvim",
      notify
    )
  end

  if type(opts.plugins) == "table" then
    for repo, settings in pairs(opts.plugins) do
      config_validate.check(
        settings,
        KNOWN_PLUGIN_OPTS,
        ("runtime-analysis.telemetry.lazy.setup() opts.plugins[%q]"):format(tostring(repo)),
        notify
      )
    end
  end

  if type(opts.extra) == "table" then
    for i, target in ipairs(opts.extra) do
      config_validate.check(
        target,
        KNOWN_EXTRA_OPTS,
        ("runtime-analysis.telemetry.lazy.setup() opts.extra[%d]"):format(i),
        notify
      )
    end
  end
end

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

---Every prefix of one `extra` target that is currently loaded. Empty when
---none is — the caller then knows there is nothing to wrap yet, rather than
---standing up an empty namespace for a config whose modules have not been
---required.
---@internal
---@param target RA.Telemetry.ExtraTarget
---@return string[]
local function loaded_mains(target)
  local telemetry = require("runtime-analysis.telemetry")
  local out = {}
  for _, main in ipairs(target.mains or {}) do
    if type(main) == "string" and main ~= "" and telemetry.module_loaded(main) then
      out[#out + 1] = main
    end
  end
  return out
end

---Wrap and start one `extra` target across every prefix of it that is loaded.
---
---Deliberately NOT `telemetry.auto()`, which the `plugins` path uses: that
---helper is built around exactly one `main` and creates its own instance per
---call, so calling it once per prefix would produce N instances sharing one
---namespace — N wrappers writing one cache file, the exact "merged, wrong
---numbers" collision `telemetry.new()` warns about. One instance, N
---`wrap_loaded()` calls, is the only correct shape here.
---@internal
---@param target RA.Telemetry.ExtraTarget
---@return boolean wrapped  # false when nothing of this target is loaded yet
local function wrap_extra(target)
  local mains = loaded_mains(target)
  if #mains == 0 then
    return false
  end

  local telemetry = require("runtime-analysis.telemetry")
  local inst = telemetry.get(target.namespace)
    or telemetry.new({
      namespace = target.namespace,
      persist = target.persist,
      dir = target.dir,
    })

  for _, main in ipairs(mains) do
    -- `deep` defaults to TRUE here, unlike `LazyPluginOpts.deep`: a plugin
    -- has a façade worth wrapping on its own, a config prefix does not --
    -- `require("bindings")` is not where a config's functions live.
    if target.deep ~= false then
      inst.wrap_loaded(main, { module_filter = telemetry.default_module_filter })
    else
      inst.wrap(package.loaded[main] or package.loaded[main .. ".init"])
    end
  end

  inst.start({
    profile_args = target.profile_args or nil,
    time = target.timing or nil,
  })
  return true
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

---Schedule every `extra` target according to its own `wrap_at`.
---
---Runs BEFORE the lazy.nvim guard in `M.setup()` below, on purpose: an
---`extra` target resolves entirely through `package.loaded` and must keep
---working for a reader whose plugin manager is not lazy.nvim (or who has
---none at all) -- the guard is about `opts.plugins`, not about this.
---@internal
---@param extra RA.Telemetry.ExtraTarget[]
local function setup_extra(extra)
  local deferred = {}

  for _, target in ipairs(extra) do
    if type(target) == "table" and type(target.namespace) == "string" then
      local wrap_at = target.wrap_at or "VimEnter"
      if wrap_at == "setup" then
        wrap_extra(target)
      elseif wrap_at ~= "manual" then
        deferred[#deferred + 1] = target
      end
    end
  end

  if #deferred == 0 then
    return
  end

  local function wrap_deferred()
    for _, target in ipairs(deferred) do
      wrap_extra(target)
    end
  end

  -- `vim.schedule` after VimEnter, not VimEnter itself: a config's own
  -- VimEnter-registered phases (this one included) all fire in registration
  -- order, and anything a config defers with its own `vim.schedule` from
  -- there would otherwise still be unloaded when this runs. Scheduling puts
  -- this behind them on the same queue.
  --
  -- The already-entered case is real, not defensive: `:Lazy reload`, a
  -- re-sourced config, or any `setup()` call made after startup would
  -- otherwise wait for a VimEnter that has already happened and never wrap
  -- at all -- silently, which is the failure mode worth spending this branch
  -- to avoid.
  if vim.v.vim_did_enter == 1 then
    vim.schedule(wrap_deferred)
  else
    autocmd.create("VimEnter", function()
      vim.schedule(wrap_deferred)
    end, {
      once = true,
      group = autocmd.group("runtime_analysis_telemetry_extra", true),
      desc = "runtime-analysis.telemetry: wrap+start each configured `extra` target",
    })
  end
end

---@param opts RA.Telemetry.LazyOpts
function M.setup(opts)
  validate_opts(opts)

  configured = opts

  if type(opts.extra) == "table" then
    setup_extra(opts.extra)
  end

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

  -- After `lib_nvim` above, which does not depend on `plugins` at all -- a
  -- config setting only `lib_nvim` (or only `extra`) must keep working.
  if type(opts.plugins) ~= "table" or next(opts.plugins) == nil then
    return
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

  autocmd.create("User", function(args)
    if type(args.data) == "string" then
      try_wrap(args.data)
    end
  end, {
    pattern = "LazyLoad",
    group = autocmd.group("runtime_analysis_telemetry_lazyload", true),
    desc = "runtime-analysis.telemetry: wrap+start an instance for each plugin as it loads",
  })
end

---The `opts` the most recent `M.setup()` call received, unchanged --
---`nil` before `M.setup()` has run this session.
---@return RA.Telemetry.LazyOpts?
function M.configured()
  return configured
end

---Every configured target -- plugin (`M.setup()`'s own `opts.plugins`, keyed
---by repo, resolved through lazy.nvim) or `extra` (stated outright by the
---caller, resolved through `package.loaded` alone) -- that currently has at
---least one loaded root module, and is therefore actually wrappable right
---now. The list `:RATelemetrySetupAll`/`:RATelemetrySetupAllFull` and
---`:RATelemetry setup|full <ns>` (telemetry/setup_all.lua) act on.
---
---Deliberately independent of `try_wrap`'s own `started` bookkeeping above:
---that set exists so the catch-up scan and the `LazyLoad` autocmd never
---double-wrap the same plugin, which is irrelevant here -- a caller of this
---function always intends to act again (reset, re-wrap, restart), on
---purpose, regardless of whether the automatic mechanism already wrapped
---this plugin once this session.
---
---The `plugins` half is empty when lazy.nvim is not the plugin manager,
---`M.setup()` has not run yet, or `opts.plugins` was empty -- the same
---soft-dependency posture `M.setup()` itself has. The `extra` half does not
---involve lazy.nvim and survives all three.
---@return RA.Telemetry.SetupAllCandidate[]
function M.candidates()
  if not configured then
    return {}
  end

  local telemetry = require("runtime-analysis.telemetry")

  ---@type RA.Telemetry.SetupAllCandidate[]
  local extra_out = {}
  for _, target in ipairs(configured.extra or {}) do
    if type(target) == "table" and type(target.namespace) == "string" then
      local mains = loaded_mains(target)
      if #mains > 0 then
        -- `main` is set to the first loaded prefix purely so the field stays
        -- populated for any reader of the published type; `mains` is what
        -- `setup_all` actually walks. See the type's own note.
        extra_out[#extra_out + 1] = {
          repo = nil,
          namespace = target.namespace,
          main = mains[1],
          mains = mains,
          -- `deep` normalized to its real default HERE rather than left for
          -- `setup_all` to re-derive: that module reads `settings.deep` as a
          -- plain boolean (a plugin's own default is false -- wrap the
          -- façade), and an `extra` target's default is the opposite. A copy,
          -- never a mutation of the caller's own table.
          settings = vim.tbl_extend("force", target, { deep = target.deep ~= false }),
        }
      end
    end
  end

  if not configured.plugins or next(configured.plugins) == nil then
    table.sort(extra_out, function(a, b)
      return a.namespace < b.namespace
    end)
    return extra_out
  end

  local ok_config, lazy_config = pcall(require, "lazy.core.config")
  if not ok_config then
    return extra_out
  end
  local ok_loader, lazy_loader = pcall(require, "lazy.core.loader")
  if not ok_loader then
    return extra_out
  end

  ---@type RA.Telemetry.SetupAllCandidate[]
  local out = extra_out
  for _, plugin in pairs(lazy_config.plugins) do
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
