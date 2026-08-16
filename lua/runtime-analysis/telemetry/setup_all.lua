---@module 'runtime-analysis.telemetry.setup_all'
--- The mechanism behind `:RATelemetrySetupAll`/`:RATelemetrySetupAllFull` --
--- manager-agnostic orchestration over whatever `telemetry.lazy.candidates()`
--- (the one lazy.nvim-specific resolution step) hands back. Split out the
--- same way `documentation.editor.generate_all` sits apart from its own
--- `bindings/usrcmds/generate_all.lua`: this file never prompts, never
--- notifies -- a caller (`telemetry/command.lua`) owns the UI, this owns
--- "what actually happens to one candidate".
---
--- WHAT "SETUP" MEANS HERE
--- For every configured plugin currently loaded (`telemetry.lazy.candidates()`):
---   1. Flush a live instance if one exists, so a backup below reflects calls
---      already collected but not yet on disk.
---   2. Back up whatever is on disk for that namespace, if anything -- only
---      when the caller supplied `backup_dir` (`telemetry/command.lua` only
---      does this after the user confirmed a directory, once, for the whole
---      run; see that module for why a single shared prompt beats one per
---      plugin).
---   3. `reset()` -- drop the live/persisted aggregate. A no-op on an
---      instance that had nothing anyway.
---   4. Re-wrap: `wrap_loaded()`/`wrap()` again, even for a plugin already
---      fully wrapped this session. Idempotent for anything already
---      registered (`inst.wrap_loaded`'s own re-registration is a no-op),
---      and the reason this step exists at all -- it is what picks up a
---      submodule the plugin lazily required *after* its own first
---      `wrap_loaded()` snapshot (catch-up scan or `User LazyLoad`), which
---      otherwise stays permanently unwrapped: zero calls, no argument data,
---      not because profiling was off but because nothing ever hooked it.
---      See `runtime-analysis.telemetry.wrap_loaded`'s own doc-comment
---      ("WHY LOADED AND NOT EVERY MODULE ON DISK") for the same limit from
---      the other side.
---   5. `start()` -- plain mode uses this plugin's own already-configured
---      policy (`candidate.settings.profile_args`/`.timing`); `full` mode
---      (`run_opts.full = true`) forces argument profiling and timing on for
---      every candidate regardless of its individual settings, the same
---      "give me everything, once, regardless of the usual policy" posture
---      `:DocMap full`'s own LuaLS enrichment already has one repo over.

local M = {}

---Write one namespace's data out as a timestamped backup file. Exported (not
---`---@internal`) — `telemetry/command.lua`'s own `do_reset_all` reuses this
---exact routine for `:RATelemetry reset`/`:RATelemetryResetAll`'s backup
---step rather than growing a second copy of it; only the "which candidates,
---which prompt" logic around it differs between setup and a bare reset.
---@param dir string
---@param namespace string
---@param data RA.Telemetry.Data
---@return string|nil written
function M.write_backup(dir, namespace, data)
  local store = require("runtime-analysis.telemetry.store")
  local report_file = require("runtime-analysis.telemetry.report_file")

  local path = dir .. "/" .. store.sanitize(namespace) .. "-" .. os.date("%Y%m%d-%H%M%S") .. ".json"
  local payload = { backed_up_at = os.time(), namespace = namespace, data = data }

  local encoded = require("lib.lua.json").encode(payload)
  if not encoded then
    return nil
  end

  local ok = report_file.write(path, { encoded })
  return ok and path or nil
end

---@internal
---@param candidate RA.Telemetry.SetupAllCandidate
---@param full boolean
local function setup_one(candidate, full)
  local telemetry = require("runtime-analysis.telemetry")

  local inst = telemetry.get(candidate.namespace)
  if inst then
    inst.reset()
  else
    inst = telemetry.new({
      namespace = candidate.namespace,
      persist = candidate.settings.persist,
      dir = candidate.settings.dir,
    })
  end

  -- `mains or { main }`: a plugin has exactly one root module, an `extra`
  -- target (a config) usually several unrelated ones. Both go through the
  -- same instance -- one namespace, one cache file -- so this is a loop
  -- rather than a second instance per prefix.
  for _, main in ipairs(candidate.mains or { candidate.main }) do
    if candidate.settings.deep or full then
      inst.wrap_loaded(main, { module_filter = telemetry.default_module_filter })
    else
      inst.wrap(package.loaded[main] or package.loaded[main .. ".init"])
    end
  end

  inst.start({
    profile_args = (full or candidate.settings.profile_args) or nil,
    time = (full or candidate.settings.timing) or nil,
  })
end

---Run setup across every candidate `telemetry.lazy.candidates()` currently
---resolves. Synchronous -- nothing here does IO slow enough to warrant a
---callback (a JSON write per namespace, at most a few dozen namespaces), so
---`on_done`/the return value fire before this function returns, both
---offered for the same reason `documentation.editor.generate_all.run()`
---offers `on_done` despite that one genuinely being async: one call site
---(`telemetry/command.lua`) reads the return value directly, and matching
---the sibling module's shape costs nothing.
---@param run_opts { full?: boolean, backup_dir?: string, namespace?: string, on_done?: fun(results: RA.Telemetry.SetupAllResult[]) }
---`namespace` narrows the run to that single candidate (`:RATelemetry
---setup|full <ns>`); omitted, every candidate is processed
---(`:RATelemetrySetupAll`). Filtering here rather than in the caller keeps
---the backup/reset/re-wrap/start sequence identical for both -- a one-
---namespace run is the same operation, not a second implementation of it.
---@return RA.Telemetry.SetupAllResult[]
function M.run(run_opts)
  run_opts = run_opts or {}
  local telemetry = require("runtime-analysis.telemetry")
  local lazy_adapter = require("runtime-analysis.telemetry.lazy")

  ---@type RA.Telemetry.SetupAllResult[]
  local results = {}
  for _, candidate in ipairs(lazy_adapter.candidates()) do
    if not run_opts.namespace or candidate.namespace == run_opts.namespace then
      local cache_opts = { dir = candidate.settings.dir }

      -- Flush BEFORE deciding `had_data`: a live instance may hold real calls
      -- in `pending` that never hit disk yet (this session's own periodic
      -- flush has not fired), and those must count as "existing data" too --
      -- silently skipping the backup for them would be worse than the
      -- alternative this ordering pays for (see the `next(...)` check below).
      local live = telemetry.get(candidate.namespace)
      if live then
        live.flush()
      end

      -- `candidate.settings.dir` (usually unset -> the real default cache
      -- dir), not left to `telemetry.load`'s own default: a candidate with a
      -- custom cache directory must be checked *there*, not wherever most
      -- other plugins happen to persist to -- the same reasoning
      -- `documentation.editor.generate_all.autoload` already gives for
      -- checking a project's own configured `out_dir` rather than a
      -- hardcoded path.
      --
      -- A FILE existing is not the same claim as DATA existing: the flush
      -- just above writes one unconditionally for a freshly-created instance
      -- too (zero calls, `functions = {}`) -- `next(existing.functions)`
      -- distinguishes "genuinely nothing to lose" from "this plugin actually
      -- has an aggregate," which `had_data`/the backup prompt are actually
      -- asking about.
      local existing = telemetry.load(candidate.namespace, cache_opts)
      local had_data = existing ~= nil and next(existing.functions or {}) ~= nil

      local backed_up
      if had_data and run_opts.backup_dir then
        backed_up = M.write_backup(run_opts.backup_dir, candidate.namespace, existing)
      end

      setup_one(candidate, run_opts.full == true)

      results[#results + 1] = {
        namespace = candidate.namespace,
        had_data = had_data,
        backed_up = backed_up,
      }
    end
  end

  if run_opts.on_done then
    run_opts.on_done(results)
  end
  return results
end

return M
