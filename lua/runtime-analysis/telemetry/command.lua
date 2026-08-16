---@module 'runtime-analysis.telemetry.command'
--- The `:RATelemetry` control command.
---
--- Opt-in on purpose: requiring this module registers nothing. Call
--- `require("runtime-analysis.telemetry.command").setup()` from your config if you want
--- the command — a library that silently claims a user-command name is a
--- library that collides with someone's own mapping.
---
---   :RATelemetry                 report across every live instance
---   :RATelemetry lsp.nvim        report for one namespace
---   :RATelemetry start [ns]      start every instance, or just one
---   :RATelemetry stop [ns]       stop every instance, or just one
---   :RATelemetry reset [ns]      drop collected data, every instance or just one
---   :RATelemetry disable [ns]    stop + persist "off" across restarts
---   :RATelemetry enable [ns]     clear a persisted disable, resume now
---   :RATelemetry disabled        list namespaces currently disabled
---   :RATelemetry coverage        which wrapped functions were never called
---   :RATelemetry export [path]   write a snapshot (JSON, Markdown if path
---                                ends .md, PDF via pdfport.nvim if .pdf)
---   :RATelemetry export-all <dir>  one Markdown file per namespace found on
---                                disk into <dir> -- unlike `export`, not
---                                limited to this session's live instances
---   :RATelemetry open [ns]       render + open externally (report_style: auto/kit/mdview/file/html)
---   :RATelemetry compare [ns] [days]  this window vs the one before it (default 7d)
---   :RATelemetry startup [top]   which module a plugin's startup cost sits in
---   :RATelemetry cost            startup cost vs. call count, worst first
---   :RATelemetry snapshot <ns> [name]  save a named capture of ns's current
---                                aggregate (docs/ROADMAP.md §4.5) -- always
---                                explicit, nothing ever snapshots on its own
---   :RATelemetry snapshots <ns>  list ns's saved snapshots, newest first
---   :RATelemetry snapshot-compare <ns> <a> <b>  diff two named snapshots'
---                                call counts directly -- not a calendar
---                                window like `compare` above, two
---                                deliberate captures possibly taken on
---                                different machines (see `snapshot`'s own
---                                `device` tag)
---   :RATelemetry setup [ns]      backup+reset+re-wrap+(re)start -- every
---                                configured target, or just one. Same
---                                operation as :RATelemetrySetupAll, with a
---                                namespace to narrow it
---   :RATelemetry full [ns]       same, forcing arguments + timing on
---
--- `setup`/`full` are the forms that reach a target no plugin manager can
--- resolve -- above all the reader's OWN Neovim config, declared as
--- `opts.telemetry.extra` (see `RA.Telemetry.ExtraTarget`). A config has no
--- repo to select it by, so `:RATelemetry full nvim-config` is how it is
--- named; everything else here (report, compare, coverage, snapshot,
--- export, the dashboard) already treats it as an ordinary namespace.
---
--- Standalone aliases, registered alongside `:RATelemetry` by the same
--- `setup()` call — `:RATelemetry start`/`stop`/`reset` (bare) already do
--- exactly this, these exist only because "every instance" is reached for
--- often enough to earn its own command name rather than a remembered
--- subcommand:
---   :RATelemetryStartAll         same as `:RATelemetry start` (bare)
---   :RATelemetryStopAll          same as `:RATelemetry stop` (bare)
---   :RATelemetryResetAll         same as `:RATelemetry reset` (bare)
---
--- Two more, the bare-form aliases of `:RATelemetry setup`/`full` above —
--- see `runtime-analysis.telemetry.setup_all`'s own module doc-comment for
--- the full mechanism. Both act on every target `opts.telemetry.plugins`
--- and `opts.telemetry.extra` configure (the same list
--- `telemetry.lazy.setup()` already auto-wraps) that is currently loaded:
---   :RATelemetrySetupAll         back up (prompted once, only if anything
---                                would be overwritten), reset, re-wrap
---                                (picks up any submodule loaded after the
---                                first wrap — see setup_all.lua for why
---                                this is also the fix for "some functions'
---                                arguments never show up"), and (re)start
---                                every configured plugin with ITS OWN
---                                already-configured profile_args/timing
---   :RATelemetrySetupAllFull     same, but forces profile_args + timing on
---                                for every plugin regardless of its own
---                                configured policy — the `setup_all`
---                                equivalent of `:DocMap full`'s LuaLS
---                                enrichment: more expensive, on request only

local usercmd = require("lib.nvim.usercmd")
local notify = require("lib.nvim.notify").create("[runtime-analysis.telemetry]")
local report_file = require("runtime-analysis.telemetry.report_file")
local resolve_report_style = require("runtime-analysis.telemetry.report_style")
local telemetry_config = require("runtime-analysis.telemetry.config")
local mdview_renderer = require("runtime-analysis.telemetry.renderers.mdview")
local html_renderer = require("runtime-analysis.telemetry.renderers.html")

local M = {}

local SUBCOMMANDS = {
  "report",
  "start",
  "stop",
  "reset",
  "disable",
  "enable",
  "disabled",
  "coverage",
  "export",
  "export-all",
  "open",
  "compare",
  "startup",
  "cost",
  "snapshot",
  "snapshots",
  "snapshot-compare",
  "setup",
  "full",
}

---@internal
---@return RA.Telemetry
local function telemetry()
  return require("runtime-analysis.telemetry")
end

---@internal
---@param lines string[]
---@param title string
local function show(lines, title)
  local ok, kit = pcall(require, "lib.nvim.ui.kit")
  if ok then
    kit.viewer({
      lines = lines,
      title = (" %s "):format(title),
      width = math.min(110, math.max(60, vim.o.columns - 8)),
    })
    return
  end
  -- No kit (a stripped runtimepath, a headless session): the data still has to
  -- be reachable, so fall back to the message area rather than failing.
  notify.info(table.concat(lines, "\n"))
end

---@internal
---@param opts RA.Telemetry.ReportOpts
---@param namespace string|nil
---@return string[]
local function report_lines(opts, namespace)
  local mod = telemetry()
  local out = {}

  local list = mod.instances()
  if namespace then
    local inst = mod.get(namespace)
    list = inst and { inst } or {}
    if #list == 0 then
      return { ("no telemetry instance for namespace %q"):format(namespace) }
    end
  end

  if #list == 0 then
    return {
      "no telemetry instances.",
      "",
      'Create one with require("runtime-analysis.telemetry").new({ namespace = "…" }).',
    }
  end

  for i, inst in ipairs(list) do
    if i > 1 then
      out[#out + 1] = ""
      out[#out + 1] = ("─"):rep(60)
      out[#out + 1] = ""
    end
    vim.list_extend(out, inst.lines(opts))
  end
  return out
end

---`:RATelemetry compare [namespace] [days]` — docs/ROADMAP.md §4.2. Same
---"every instance, or just one" shape `report_lines` above already uses;
---`days` (default 7, `inst.compare`'s own) applies to every instance shown,
---not per-instance.
---@internal
---@param namespace string|nil
---@param days integer|nil
---@return string[]
local function compare_lines(namespace, days)
  local mod = telemetry()
  local out = {}

  local list = mod.instances()
  if namespace then
    local inst = mod.get(namespace)
    list = inst and { inst } or {}
    if #list == 0 then
      return { ("no telemetry instance for namespace %q"):format(namespace) }
    end
  end

  if #list == 0 then
    return {
      "no telemetry instances.",
      "",
      'Create one with require("runtime-analysis.telemetry").new({ namespace = "…" }).',
    }
  end

  for i, inst in ipairs(list) do
    if i > 1 then
      out[#out + 1] = ""
      out[#out + 1] = ("─"):rep(60)
      out[#out + 1] = ""
    end
    out[#out + 1] = inst.namespace .. ":"
    vim.list_extend(out, inst.compare_lines({ days = days }))
  end
  return out
end

---@internal Soft dependency on pdfport.nvim (github.com/StefanBartl/
---pdfport.nvim), same content export()'s `.md` branch writes, handed to
---pdfport as text instead of read back from a written .md file.
---@param target string
---@param callback fun(written: string|nil, err: string|nil)
local function export_pdf(target, callback)
  local mod = telemetry()

  local ok_pp, pdfport = pcall(require, "pdfport")
  if not ok_pp or type(pdfport.create) ~= "function" then
    callback(nil, "pdfport.nvim not installed -- PDF export unavailable")
    return
  end
  if type(pdfport.can_create) ~= "function" or not pdfport.can_create("markdown") then
    callback(nil, "pdfport.nvim has no available markdown producer (needs pandoc + a PDF engine)")
    return
  end

  pdfport.create({
    text = table.concat(mod.markdown_all(), "\n"),
    from = "markdown",
    output = target,
    on_conflict = "overwrite",
    __callback = function(result)
      if result.status == "ok" then
        callback(target, nil)
      else
        callback(nil, result.error or "pdfport export failed")
      end
    end,
  })
end

---@internal
---@param path string|nil
---@param pdf_callback fun(written: string|nil, err: string|nil)|nil Required
---when `path` ends `.pdf` -- that branch is asynchronous (pdfport.nvim
---shells out to pandoc) and returns nothing itself; every other branch
---stays synchronous and ignores this.
---@return string|nil written Only for the synchronous (json/markdown) branches.
local function export(path, pdf_callback)
  local mod = telemetry()

  local target = path
  if not target or target == "" then
    target = ("%s/runtime-analysis.nvim-telemetry-%s.json"):format(
      vim.fn.stdpath("cache"),
      os.date("%Y%m%d-%H%M%S")
    )
  end

  -- Format inferred from the target's own extension rather than a separate
  -- `--format` flag: this command's argument parsing is deliberately
  -- positional-only (see the module doc-comment), and ".md means Markdown"
  -- needs no flag grammar to be unambiguous.
  if target:sub(-4):lower() == ".pdf" then
    export_pdf(target, pdf_callback)
    return nil
  end

  if target:sub(-3):lower() == ".md" then
    local ok = report_file.write(target, mod.markdown_all())
    return ok and target or nil
  end

  local payload = { exported_at = os.time(), reports = mod.report_all() }

  local ok = require("lib.nvim.fs.json").write(target, payload)
  if not ok then
    return nil
  end
  return target
end

---`:RATelemetry open [ns]` — render + hand the report to whatever
---`report_style` resolves to. Always forces a flush first: the honest-limits
---note in the roadmap doc is explicit that the browser shows the *last*
---flush, and `open` is the one moment that promise should hold as tightly as
---possible.
---@internal
---@param namespace string|nil
local function open_report(namespace)
  local mod = telemetry()
  local style = resolve_report_style(telemetry_config.report_style())

  ---@param lines string[]
  ---@param path string
  ---@param kit_lines string[]
  ---@param title string
  ---@param reports RA.Telemetry.Report[] docs/ROADMAP.md §4.4 — only the "html" branch reads this; every other branch already has what it needs in `lines`/`kit_lines`.
  ---@param html_path string
  local function dispatch(lines, path, kit_lines, title, reports, html_path)
    if style == "mdview" then
      local ok, err = mdview_renderer.open(lines, path)
      if not ok then
        notify.warn(("mdview open failed (%s) — falling back to the kit float"):format(err))
        show(kit_lines, title)
      end
    elseif style == "file" then
      local ok, err = report_file.write(path, lines)
      if ok then
        notify.info("wrote " .. path)
      else
        notify.error("failed to write report: " .. tostring(err))
      end
    elseif style == "html" then
      local html = html_renderer.render(reports)
      local ok, err = report_file.write(html_path, { html })
      if not ok then
        notify.error("failed to write dashboard: " .. tostring(err))
        return
      end
      local ok_open = pcall(function()
        require("lib.nvim.fs.open.url.system_opener").open(html_path)
      end)
      if ok_open then
        notify.info("wrote and opened " .. html_path)
      else
        notify.info("wrote " .. html_path .. " — open it yourself, no system opener available")
      end
    else -- "kit"
      show(kit_lines, title)
    end
  end

  if namespace and namespace ~= "" then
    local inst = mod.get(namespace)
    if not inst then
      notify.warn(("no telemetry instance for namespace %q"):format(namespace))
      return
    end
    inst.flush()
    dispatch(
      inst.markdown(),
      report_file.namespace_path(namespace, inst._cache_opts),
      inst.lines(),
      ("runtime-analysis.telemetry — %s"):format(namespace),
      { inst.report() },
      report_file.namespace_html_path(namespace, inst._cache_opts)
    )
    return
  end

  -- Bare: every instance, combined — a snapshot at invocation time. Only a
  -- per-namespace open can be truly self-updating (see report_file.lua):
  -- the combined file has no single flush cycle that owns it.
  for _, inst in ipairs(mod.instances()) do
    inst.flush()
  end
  dispatch(
    mod.markdown_all({ sort = "calls", top = 40 }),
    report_file.combined_path(),
    report_lines({ sort = "calls", top = 40 }, nil),
    "runtime-analysis.telemetry",
    mod.report_all({ sort = "calls", top = 40 }),
    report_file.combined_html_path()
  )
end

---`:RATelemetrySetupAll` / `:RATelemetrySetupAllFull` — the UI half of
---`runtime-analysis.telemetry.setup_all`; see that module's own doc-comment
---for what "setup" actually does to each candidate.
---
---**One prompt for the whole run, not one per plugin.** Backing up N
---plugins' worth of existing data behind N separate `vim.ui.input()`
---dialogs is the kind of tedium that trains a reader to mash Enter without
---reading any of them — the same failure mode a repeated confirmation
---dialog always has. So every candidate with existing data shares one
---directory, chosen once, before anything is touched; a candidate with
---nothing on disk needs no backup and is never why the prompt appeared.
---Declining (`<Esc>`/empty input) aborts the entire run — existing data is
---either backed up everywhere it exists, or nothing is reset anywhere,
---never a partial run silently dropping some of it.
---@internal
---@param full boolean
---@param namespace string|nil When set, only that candidate is acted on
---(`:RATelemetry setup|full <ns>`); the whole prompt/backup/report flow is
---otherwise identical, so both forms share this one function rather than
---growing a second near-copy of it.
local function do_setup_all(full, namespace)
  local lazy_adapter = require("runtime-analysis.telemetry.lazy")
  local candidates = lazy_adapter.candidates()
  if namespace and namespace ~= "" then
    candidates = vim.tbl_filter(function(c)
      return c.namespace == namespace
    end, candidates)
    if #candidates == 0 then
      notify.warn(
        ("%q is not a configured, currently-loaded target -- nothing to set up "):format(namespace)
          .. "(see opts.telemetry.plugins / opts.telemetry.extra passed to runtime-analysis.setup())"
      )
      return
    end
  end
  if #candidates == 0 then
    notify.warn(
      "no configured plugin or extra target is loaded yet -- nothing to set up "
        .. "(see opts.telemetry.plugins / opts.telemetry.extra passed to runtime-analysis.setup())"
    )
    return
  end

  local mod = telemetry()
  local any_existing = false
  for _, c in ipairs(candidates) do
    -- `c.settings.dir`, not `load`'s own default: a target with a custom
    -- cache directory keeps its data THERE, and checking the default
    -- instead would report "nothing to lose" for it -- skipping the backup
    -- prompt before `setup_all.run()` resets exactly the data the prompt
    -- exists to protect. Same reasoning `setup_all.run()` already applies
    -- for its own `had_data` check.
    --
    -- `nil` when there is no override, NOT `{ dir = nil }`: `M.load` falls
    -- back to this plugin's own cache root only when `opts` itself is nil,
    -- and an empty table would instead reach `cache.disk`'s unrelated
    -- built-in default (lib.nvim's root) -- reading the wrong directory for
    -- every ordinary target, which is most of them.
    if mod.load(c.namespace, c.settings.dir and { dir = c.settings.dir } or nil) then
      any_existing = true
      break
    end
  end

  ---@param backup_dir string|nil
  local function proceed(backup_dir)
    local results = require("runtime-analysis.telemetry.setup_all").run({
      full = full,
      backup_dir = backup_dir,
      namespace = namespace,
    })

    local backed_up = 0
    for _, r in ipairs(results) do
      if r.backed_up then
        backed_up = backed_up + 1
      end
    end

    -- "target(s)", not "plugin(s)": an `extra` entry is typically the
    -- reader's own config, which is not a plugin and reads as a mistake if
    -- called one.
    notify.info(
      ("set up %d target(s) (%s)%s"):format(
        #results,
        full and "full: deep + arguments + timing" or "each target's own configured policy",
        backed_up > 0 and (", backed up %d with existing data to %s"):format(backed_up, backup_dir)
          or ""
      )
    )
  end

  if not any_existing then
    proceed(nil)
    return
  end

  local default_dir = vim.fn.stdpath("cache") .. "/runtime-analysis.nvim/setup-all-backups"

  local function on_input(input)
    if input == nil or vim.trim(input) == "" then
      notify.warn("setup aborted -- existing telemetry data left untouched")
      return
    end
    local dir = vim.trim(input)
    local ok_mkdir = require("lib.nvim.fs.mkdirp")(dir)
    if not ok_mkdir or vim.fn.isdirectory(dir) == 0 then
      notify.error("could not create backup directory: " .. dir)
      return
    end
    proceed(dir)
  end

  local ok_kit, kit = pcall(require, "lib.nvim.ui.kit")
  if ok_kit then
    kit.input({
      title = "runtime-analysis.telemetry: back up existing data to (created if missing): ",
      default = default_dir,
      on_submit = on_input,
    })
  else
    vim.ui.input({
      prompt = "runtime-analysis.telemetry: back up existing data to (created if missing): ",
      default = default_dir,
    }, on_input)
  end
end

---Register `:RATelemetry`. Idempotent (`usercmd.create` defaults to `force`).
function M.setup()
  usercmd.create("RATelemetry", function(args)
    local mod = telemetry()
    local first = args.fargs[1]
    local rest = args.fargs[2]

    if first == "start" or first == "stop" or first == "reset" then
      -- A bare `rest` is a namespace, e.g. `:RATelemetry stop markdown.nvim`
      -- — every other subcommand that takes one puts it in the same slot, so
      -- this stays consistent with `:RATelemetry <namespace>` (report).
      if rest and rest ~= "" then
        local inst = mod.get(rest)
        if not inst then
          notify.warn(("no telemetry instance for namespace %q"):format(rest))
          return
        end
        if first == "start" then
          inst.start()
          notify.info(("started %s"):format(rest))
        elseif first == "stop" then
          inst.stop()
          notify.info(("stopped %s"):format(rest))
        else
          inst.reset()
          notify.info(("collected data cleared for %s"):format(rest))
        end
        return
      end

      if first == "start" then
        notify.info(("started %d instance(s)"):format(mod.start_all()))
      elseif first == "stop" then
        notify.info(("stopped %d instance(s)"):format(mod.stop_all()))
      else
        for _, inst in ipairs(mod.instances()) do
          inst.reset()
        end
        notify.info("collected data cleared")
      end
    elseif first == "disable" or first == "enable" then
      -- Unlike start/stop/reset, a namespace here does NOT need a live
      -- instance to exist — disabling something before it has ever loaded
      -- this session is the common case, not an edge case.
      if rest and rest ~= "" then
        mod[first](rest)
        notify.info(("%sd %s"):format(first, rest))
        return
      end

      local n = 0
      for _, inst in ipairs(mod.instances()) do
        mod[first](inst.namespace)
        n = n + 1
      end
      notify.info(("%sd %d instance(s)"):format(first, n))
    elseif first == "disabled" then
      local list = mod.disabled()
      show(
        #list > 0 and list or { "no namespace is currently disabled." },
        "runtime-analysis.telemetry — disabled"
      )
    elseif first == "coverage" then
      local lines = {}
      for _, inst in ipairs(mod.instances()) do
        local cov = inst.coverage()
        lines[#lines + 1] = ("%s — %d called, %d never called"):format(
          inst.namespace,
          #cov.called,
          #cov.uncalled
        )
        for _, key in ipairs(cov.uncalled) do
          lines[#lines + 1] = "  · " .. key
        end
        lines[#lines + 1] = ""
      end
      show(
        #lines > 0 and lines or { "no telemetry instances." },
        "runtime-analysis.telemetry coverage"
      )
    elseif first == "export" then
      if rest and rest:sub(-4):lower() == ".pdf" then
        export(rest, function(written, err)
          if written then
            notify.info("wrote " .. written)
          else
            notify.error("export failed: " .. tostring(err))
          end
        end)
      else
        local written = export(rest)
        if written then
          notify.info("wrote " .. written)
        else
          notify.error("export failed")
        end
      end
    elseif first == "export-all" then
      if not rest or rest == "" then
        notify.warn("usage: :RATelemetry export-all <dir>")
        return
      end
      local written, failed = mod.export_all(rest)
      if #failed > 0 then
        notify.warn(
          ("wrote %d report(s) to %s, %d failed: %s"):format(
            #written,
            rest,
            #failed,
            table.concat(failed, ", ")
          )
        )
      elseif #written == 0 then
        notify.warn("no telemetry data found to export")
      else
        notify.info(("wrote %d report(s) to %s"):format(#written, rest))
      end
    elseif first == "open" then
      open_report(rest)
    elseif first == "startup" then
      -- docs/ROADMAP.md §3.3. Namespace-free on purpose: this measures
      -- module loads, not one namespace's wrapped functions, so the
      -- second slot every other subcommand uses for a namespace is a
      -- `top` count here instead.
      local startup = require("runtime-analysis.telemetry.startup")
      show(
        startup.lines(startup.report({ top = tonumber(rest) or 40 })),
        "runtime-analysis.telemetry — startup"
      )
    elseif first == "cost" then
      -- docs/ROADMAP.md §7.2. No arguments: this is inherently cross-
      -- namespace (a per-namespace `cost` would just repeat `report`'s own
      -- call count with one extra number), and it reads live startup data
      -- rather than anything this instance itself persists.
      local startup = require("runtime-analysis.telemetry.startup")
      local cost_vs_use = require("runtime-analysis.telemetry.cost_vs_use")
      local namespaces = {}
      for _, inst in ipairs(mod.instances()) do
        namespaces[#namespaces + 1] = {
          namespace = inst.namespace,
          resolved_modules = inst.resolved_modules(),
          total_calls = inst.report().total_calls,
        }
      end
      show(
        cost_vs_use.lines(cost_vs_use.build_all(namespaces, startup.report())),
        "runtime-analysis.telemetry — cost vs use"
      )
    elseif first == "snapshot" then
      -- `rest` is the namespace, same slot every other subcommand puts it
      -- in; a third token, if present, is the snapshot's own name. Requires
      -- a namespace explicitly (unlike start/stop/reset's "every instance"
      -- fallback) -- a bare `:RATelemetry snapshot` snapshotting every live
      -- instance at once under the same auto-generated timestamp would be a
      -- surprising amount of silent disk writing for a command whose whole
      -- point is being explicit.
      if not rest or rest == "" then
        notify.warn("usage: :RATelemetry snapshot <namespace> [name]")
        return
      end
      local saved_name = mod.snapshot(rest, args.fargs[3])
      if saved_name then
        notify.info(("saved snapshot %q for %s"):format(saved_name, rest))
      else
        notify.warn(
          ("nothing to snapshot for %q -- no live instance and nothing persisted yet"):format(rest)
        )
      end
    elseif first == "snapshots" then
      if not rest or rest == "" then
        notify.warn("usage: :RATelemetry snapshots <namespace>")
        return
      end
      local list = mod.list_snapshots(rest)
      if #list == 0 then
        show(
          { ("no snapshots saved for %s yet."):format(rest) },
          "runtime-analysis.telemetry — snapshots"
        )
        return
      end
      local lines = {}
      for _, s in ipairs(list) do
        lines[#lines + 1] = ("%s — %s"):format(s.name, os.date("%Y-%m-%d %H:%M:%S", s.saved_at))
      end
      show(lines, ("runtime-analysis.telemetry — snapshots (%s)"):format(rest))
    elseif first == "snapshot-compare" then
      local name_a, name_b = args.fargs[3], args.fargs[4]
      if not rest or rest == "" or not name_a or not name_b then
        notify.warn("usage: :RATelemetry snapshot-compare <namespace> <name_a> <name_b>")
        return
      end
      local cmp = mod.compare_snapshots(rest, name_a, name_b)
      if not cmp then
        notify.warn(("%q or %q not found among %s's saved snapshots"):format(name_a, name_b, rest))
        return
      end
      show(
        require("runtime-analysis.telemetry.report").compare_snapshots_lines(cmp),
        "runtime-analysis.telemetry — snapshot compare"
      )
    elseif first == "setup" or first == "full" then
      -- `:RATelemetry setup|full [namespace]` -- the same backup/reset/
      -- re-wrap/start `:RATelemetrySetupAll`/`SetupAllFull` run, narrowed to
      -- one target when a namespace is given. `full` forces argument
      -- profiling + timing on regardless of that target's own policy, the
      -- identical meaning it has in `:RATelemetrySetupAllFull`.
      --
      -- This is the form that reaches a NON-plugin target -- chiefly the
      -- reader's own config, declared as `opts.telemetry.extra` -- since a
      -- config has no repo to name and could never be selected the way a
      -- plugin is. `:RATelemetry full nvim-config` is the motivating case.
      do_setup_all(first == "full", rest)
    elseif first == "compare" then
      -- `rest` is a namespace exactly the way every other subcommand's
      -- second slot already is; a third token, if numeric, overrides
      -- inst.compare()'s own default window (7 days) — deliberately not
      -- validated beyond `tonumber` (a non-numeric third token is simply
      -- ignored, same posture `report`'s own bare-namespace fallthrough
      -- takes on anything it does not specifically recognize).
      local days = tonumber(args.fargs[3])
      show(compare_lines(rest, days), "runtime-analysis.telemetry — compare")
    else
      -- "report" (explicit or implied) — a bare namespace is the common case.
      local namespace = first
      if first == nil or first == "report" then
        namespace = rest
      end
      show(report_lines({ sort = "calls", top = 40 }, namespace), "runtime-analysis.telemetry")
    end
  end, {
    nargs = "*",
    desc = "runtime-analysis.telemetry: report|start|stop|reset|disable|enable|disabled|coverage|export|export-all|open|compare|startup|cost|snapshot|snapshots|snapshot-compare|setup|full [namespace] [days]",
    complete = function(arg_lead, cmd_line)
      -- Second token of `start`/`stop`/`reset`/`open`/`compare` is always a
      -- namespace, never another subcommand — narrow completion there
      -- instead of offering "start"/"stop"/... again as if it were a third
      -- grammar position. `compare`'s own third token (a day count) has no
      -- useful completion list, so it is simply left uncompleted rather
      -- than offering namespaces there too.
      local before = cmd_line:sub(1, #cmd_line - #arg_lead)
      local sub = before:match("^%S+%s+(%S+)%s+%S*$")

      local takes_namespace = sub == "start"
        or sub == "stop"
        or sub == "reset"
        or sub == "disable"
        or sub == "enable"
        or sub == "open"
        or sub == "compare"
        or sub == "snapshot"
        or sub == "snapshots"
        or sub == "snapshot-compare"
        or sub == "setup"
        or sub == "full"

      local out = {}
      if takes_namespace then
        for _, inst in ipairs(telemetry().instances()) do
          out[#out + 1] = inst.namespace
        end
      else
        for _, s in ipairs(SUBCOMMANDS) do
          out[#out + 1] = s
        end
        for _, inst in ipairs(telemetry().instances()) do
          out[#out + 1] = inst.namespace
        end
      end

      return vim.tbl_filter(function(c)
        return c:find(arg_lead or "", 1, true) == 1
      end, out)
    end,
  })

  -- Standalone aliases for the bare (no-namespace) start/stop forms above —
  -- see the module doc-comment for why these exist alongside, not instead
  -- of, `:RATelemetry start`/`stop`.
  usercmd.create(
    "RATelemetryStartAll",
    function()
      notify.info(("started %d instance(s)"):format(telemetry().start_all()))
    end,
    { desc = "runtime-analysis.telemetry: start every live instance (same as :RATelemetry start)" }
  )

  usercmd.create(
    "RATelemetryStopAll",
    function()
      notify.info(("stopped %d instance(s)"):format(telemetry().stop_all()))
    end,
    { desc = "runtime-analysis.telemetry: stop every live instance (same as :RATelemetry stop)" }
  )

  usercmd.create(
    "RATelemetryResetAll",
    function()
      for _, inst in ipairs(telemetry().instances()) do
        inst.reset()
      end
      notify.info("collected data cleared for every live instance")
    end,
    { desc = "runtime-analysis.telemetry: reset every live instance (same as :RATelemetry reset)" }
  )

  usercmd.create("RATelemetrySetupAll", function()
    do_setup_all(false, nil)
  end, {
    desc = "runtime-analysis.telemetry: backup+reset+re-wrap+start every configured, loaded target "
      .. "(own profile_args/timing policy)",
  })

  usercmd.create("RATelemetrySetupAllFull", function()
    do_setup_all(true, nil)
  end, {
    desc = "runtime-analysis.telemetry: same as :RATelemetrySetupAll, forcing profile_args + timing on",
  })
end

M.SUBCOMMANDS = SUBCOMMANDS

return M
