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
---   :RATelemetry status          one compact block per namespace this
---                                plugin knows about -- live this session or
---                                only ever persisted -- naming its state,
---                                mode and what is actually on disk for it.
---                                `<CR>` on a row still opens that
---                                namespace's own full report
---   :RATelemetry start [ns]      start every instance, or just one
---   :RATelemetry stop [ns]       stop every instance, or just one
---   :RATelemetry flush [ns]      write what has been collected so far to
---                                disk, without stopping anything -- every
---                                instance, or just one. Counters are also
---                                flushed on a timer (`flush_interval_ms`,
---                                60s by default), on `stop`, and on
---                                `VimLeavePre`, so this is for the moment
---                                you want the file to be current *now*
---                                rather than within the minute
---   :RATelemetry reset [ns]      back up (prompted once, only if anything
---                                would be lost), then drop collected data --
---                                every instance, or just one
---   :RATelemetry disable [ns]    stop + persist "off" across restarts
---   :RATelemetry enable [ns]     clear a persisted disable, resume now
---   :RATelemetry disabled        list namespaces currently disabled
---   :RATelemetry coverage        which wrapped functions were never called
---   :RATelemetry export [path]   write a snapshot (JSON, Markdown if path
---                                ends .md, PDF via pdfport.nvim if .pdf)
---   :RATelemetry export-all <dir>  one Markdown file per namespace found on
---                                disk into <dir> -- unlike `export`, not
---                                limited to this session's live instances
---   :RATelemetry open [ns]       render + open (report_style: auto/kit/preview-tab/mdview/file/html)
---   :RATelemetry compare [ns] [days]  this window vs the one before it (default 7d)
---   :RATelemetry startup [top]   which module a plugin's startup cost sits in
---   :RATelemetry flamegraph [path]  the same startup data as a flamegraph SVG
---                                -- width is time, depth is require nesting.
---                                Drawn in the terminal by images.nvim when
---                                it is installed, otherwise handed to the
---                                system opener. Without a path it lands in
---                                the disposable cache directory
---   :RATelemetry cost            startup cost vs. call count, worst first
---   :RATelemetry snapshot <ns> [name]  save a named capture of ns's current
---                                aggregate -- always
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
--- `reset` (both the bare form and `ResetAll`) asks the same one-prompt-for-
--- the-whole-run backup question `:RATelemetrySetupAll` below already does,
--- via the identical `setup_all.write_backup` routine — see `do_reset_all`
--- for why this earned the same treatment instead of resetting silently:
--- dropping a namespace's whole aggregate is exactly the kind of action
--- that deserves the chance to keep a copy first. Declining
--- (`<Esc>`/empty input) aborts the reset entirely, same semantics as
--- `do_setup_all`.
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

local usercmd = require("lib.nvim.bindings.usercmd")
local notify = require("lib.nvim.notify").create("[runtime-analysis.telemetry]")
local report_file = require("runtime-analysis.telemetry.report_file")
local resolve_report_style = require("runtime-analysis.telemetry.report_style")
local preview_tab_renderer = require("runtime-analysis.telemetry.renderers.preview_tab")
local telemetry_config = require("runtime-analysis.telemetry.config")
local mdview_renderer = require("runtime-analysis.telemetry.renderers.mdview")
local html_renderer = require("runtime-analysis.telemetry.renderers.html")

local M = {}

---One backup directory for every prompt that offers one -- `:RATelemetry
---setup|full`/`:RATelemetrySetupAll*` and `:RATelemetry reset`/
---`:RATelemetryResetAll` used to suggest two different sibling dirs, which
---scattered backups of the same data across the cache root depending on
---which command happened to ask. It sits under the telemetry cache dir
---(`DEFAULT_CACHE_DIR` in `telemetry/init.lua`) so a backup lives next to
---the data it is a copy of. Still only a *default*: the prompt is editable
---and any answer is honoured.
local DEFAULT_BACKUP_DIR = vim.fn.stdpath("cache")
  .. "/runtime-analysis.nvim/cache/telemetry/Backups"

---What every backup prompt asks, naming the file it is about to write.
---
---A directory is what the prompt takes, and the file name is not the
---reader's to choose — `setup_all.write_backup` builds it as
---`<namespace>-YYYYMMDD-HHMMSS.json` so two backups of the same namespace
---never collide and the newest sorts last. That was already true and
---invisible: the prompt asked for a path and said nothing about what would
---appear there, which reads like "pick a filename" and answers a question
---nobody could otherwise answer without opening the directory afterwards.
---
---Also spells out the two ways to *not* get a path prompt in return:
---submitting empty (`<CR>` on a cleared line) means "proceed, no backup" --
---`<Esc>` means "abort, touch nothing". See `prompt_backup_dir` for why
---those are two different outcomes rather than one.
local BACKUP_PROMPT = "runtime-analysis.telemetry: back up existing data to "
  .. "(created if missing; files are <namespace>-YYYYMMDD-HHMMSS.json; "
  .. "empty = proceed without backup, <Esc> = abort): "

---Prompt for a backup directory, shared by `do_setup_all`/`do_reset_all`.
---Distinguishes three outcomes rather than collapsing them into two:
---  - a typed path       -> back up there, then proceed
---  - submitted empty    -> proceed WITHOUT a backup (explicit, not a mistake)
---  - `<Esc>`            -> abort the whole run, existing data untouched
---`vim.ui.input`'s own contract already keeps "submitted empty" and
---"cancelled" apart -- the callback gets `nil` on `<Esc>` and the (possibly
---empty) typed string on `<CR>` -- so this only has to route the two rather
---than invent a sentinel to tell them apart.
---@param on_backup fun(dir: string|nil)  # nil means "proceed without a backup"
---@param on_abort fun()
local function prompt_backup_dir(on_backup, on_abort)
  local function on_input(input)
    if input == nil then
      on_abort()
      return
    end
    local dir = vim.trim(input)
    if dir == "" then
      on_backup(nil)
      return
    end
    local ok_mkdir = require("lib.nvim.fs.mkdirp")(dir)
    if not ok_mkdir or vim.fn.isdirectory(dir) == 0 then
      notify.error("could not create backup directory: " .. dir)
      return
    end
    on_backup(dir)
  end

  local ok_kit, kit = pcall(require, "lib.nvim.ui.kit")
  if ok_kit then
    kit.input({
      title = BACKUP_PROMPT,
      default = DEFAULT_BACKUP_DIR,
      on_submit = on_input,
      on_cancel = on_abort,
    })
  else
    vim.ui.input({
      prompt = BACKUP_PROMPT,
      default = DEFAULT_BACKUP_DIR,
    }, on_input)
  end
end

local SUBCOMMANDS = {
  "report",
  "status",
  "start",
  "stop",
  "flush",
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
  "flamegraph",
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
---A header row's namespace, if `line` is one — every per-instance block in
---`report.lines()`/`report_lines()` starts with exactly
---`("%s  —  %s"):format(namespace, state)` (see report.lua).
---@param line string
---@return string|nil
local function header_namespace(line)
  return line:match("^(%S[^\n]-)  —  %S+$")
end

---@internal
---Read-only cheatsheet for a `show()` float — only lists the actions this
---particular call actually wired up.
---@param title string
---@param rows { lhs: string, desc: string }[]
---@return nil
local function show_help(title, rows)
  local widest = #"?"
  for _, r in ipairs(rows) do
    widest = math.max(widest, #r.lhs)
  end
  local lines = { "", (" %s keys"):format(title), "" }
  local function row(lhs, desc)
    lines[#lines + 1] = ("  %-" .. widest .. "s   %s"):format(lhs, desc)
  end
  for _, r in ipairs(rows) do
    row(r.lhs, r.desc)
  end
  row("?", "Show this help")
  lines[#lines + 1] = ""
  local width = 40
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  require("lib.nvim.ui.kit").viewer({
    lines = lines,
    title = title .. " Keys",
    filetype = "runtime-analysis-telemetry-help",
    width = math.min(width + 2, math.floor(vim.o.columns * 0.9)),
    height = math.min(#lines, math.floor(vim.o.lines * 0.8)),
  })
end

---@internal
---@param lines string[]
---@param title string
---@param opts { on_refresh: (fun(): string[])|nil, on_drilldown: (fun(namespace: string): string[]|nil, string|nil)|nil, on_open_html: (fun(): nil)|nil }|nil
---`on_refresh` recomputes and returns fresh lines for the same view.
---`on_drilldown` is offered the namespace under the cursor on `<CR>` over a
---header row; returning `lines[, title]` swaps this same float to that
---namespace's own view in place, returning nothing leaves the float as is.
---`on_open_html` writes+opens this same report's HTML rendering in the
---system browser.
local function show(lines, title, opts)
  opts = opts or {}
  local ok, kit = pcall(require, "lib.nvim.ui.kit")
  if not ok then
    -- No kit (a stripped runtimepath, a headless session): the data still
    -- has to be reachable, so fall back to the message area rather than
    -- failing.
    notify.info(table.concat(lines, "\n"))
    return
  end

  local surf = kit.viewer({
    lines = lines,
    title = (" %s "):format(title),
    width = math.min(110, math.max(60, vim.o.columns - 8)),
  })
  if not surf then
    return
  end

  local help_rows = { { lhs = "j/k", desc = "Move" } }
  local km = { noremap = true, silent = true, buffer = surf.bufnr }
  local keymap = require("lib.nvim.bindings.keymap")

  if opts.on_refresh then
    help_rows[#help_rows + 1] = { lhs = "r", desc = "Refresh" }
    keymap("n", "r", function()
      local fresh = opts.on_refresh()
      if fresh then
        surf:set_lines(fresh)
      end
    end, km, "runtime-analysis.telemetry: refresh")
  end
  if opts.on_drilldown then
    help_rows[#help_rows + 1] = { lhs = "<CR>", desc = "Open the namespace under the cursor" }
    keymap("n", "<CR>", function()
      local ns = header_namespace(vim.api.nvim_get_current_line())
      if not ns then
        return
      end
      local new_lines, new_title = opts.on_drilldown(ns)
      if new_lines then
        surf:set_lines(new_lines)
        if new_title then
          surf:set_title((" %s "):format(new_title))
        end
      end
    end, km, "runtime-analysis.telemetry: drill into namespace")
  end
  if opts.on_open_html then
    help_rows[#help_rows + 1] = { lhs = "gO", desc = "Open this report as HTML in the browser" }
    keymap("n", "gO", opts.on_open_html, km, "runtime-analysis.telemetry: open as HTML")
  end
  help_rows[#help_rows + 1] = { lhs = "q, <Esc>", desc = "Close" }

  keymap("n", "?", function()
    show_help(title, help_rows)
  end, km, "runtime-analysis.telemetry: show keymap cheatsheet")
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

---`:RATelemetry compare [namespace] [days]` — Same
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
    -- Required for this branch and only this branch (see the @param above):
    -- without it the asynchronous result would have nowhere to go.
    assert(pdf_callback, "export(): a .pdf target needs a callback")
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
  ---@param reports RA.Telemetry.Report[] only the "html" branch reads this; every other branch already has what it needs in `lines`/`kit_lines`.
  ---@param html_path string
  local function dispatch(lines, path, kit_lines, title, reports, html_path)
    local function open_html()
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
    end

    -- Wired onto every "kit" float this dispatch can produce (the primary
    -- style itself, or its mdview/preview-tab failure fallback) so `r`/`gO`
    -- work the same regardless of which branch below actually opened it.
    -- `<CR>`-drilldown only makes sense on the bare "every instance" view —
    -- a single-namespace float's only header row is already itself.
    local show_opts = { on_open_html = open_html }
    if namespace and namespace ~= "" then
      show_opts.on_refresh = function()
        local inst = mod.get(namespace)
        if not inst then
          return nil
        end
        inst.flush()
        return inst.lines()
      end
    else
      show_opts.on_refresh = function()
        for _, inst in ipairs(mod.instances()) do
          inst.flush()
        end
        return report_lines({ sort = "calls", top = 40 }, nil)
      end
      show_opts.on_drilldown = function(ns)
        local inst = mod.get(ns)
        if not inst then
          return nil
        end
        inst.flush()
        return inst.lines(), ("runtime-analysis.telemetry — %s"):format(ns)
      end
    end

    if style == "mdview" then
      local ok, err = mdview_renderer.open(lines, path)
      if not ok then
        notify.warn(("mdview open failed (%s) — falling back to the kit float"):format(err))
        show(kit_lines, title, show_opts)
      end
    elseif style == "preview-tab" then
      -- `lines`, not `kit_lines`: this is the Markdown report, rendered by
      -- mdview's conceal rather than flattened for a float. The float's own
      -- lines are what the fallback below uses, which is the whole reason
      -- both are passed in.
      local ok, err = preview_tab_renderer.open(lines, title)
      if not ok then
        notify.warn(("in-editor preview failed (%s) — falling back to the kit float"):format(err))
        show(kit_lines, title, show_opts)
      end
    elseif style == "file" then
      local ok, err = report_file.write(path, lines)
      if ok then
        notify.info("wrote " .. path)
      else
        notify.error("failed to write report: " .. tostring(err))
      end
    elseif style == "html" then
      open_html()
    else -- "kit"
      show(kit_lines, title, show_opts)
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
---Submitting empty proceeds without a backup; `<Esc>` aborts the entire run
---instead — existing data is either backed up everywhere it exists, or
---nothing is reset anywhere, never a partial run silently dropping some of
---it. See `prompt_backup_dir` for why those are two different outcomes.
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

  prompt_backup_dir(proceed, function()
    notify.warn("setup aborted -- existing telemetry data left untouched")
  end)
end

---`:RATelemetry reset [ns]` / `:RATelemetryResetAll` — same one-prompt-for-
---the-whole-run backup question `do_setup_all` above already asks, applied
---to a plain reset instead of the fuller backup+reset+re-wrap+start
---sequence: a namespace's whole aggregate is gone either way, and `reset`
---deserves the same chance to keep a copy first that `setup`/`full` already
---have. Reuses `setup_all.write_backup` for the actual backup write rather
---than a second copy of that JSON-encoding logic.
---
---Unlike `do_setup_all`, this walks LIVE instances (`mod.instances()`), not
---`telemetry.lazy.candidates()` — `reset` has always acted on whatever is
---currently running in this session, configured or not, and that scope does
---not change just because a backup step was added in front of it.
---@internal
---@param namespace string|nil When set, only that instance is reset
---(`:RATelemetry reset <ns>`); omitted, every live instance is (bare
---`:RATelemetry reset` / `:RATelemetryResetAll`).
local function do_reset_all(namespace)
  local mod = telemetry()
  local setup_all = require("runtime-analysis.telemetry.setup_all")

  local list = mod.instances()
  if namespace and namespace ~= "" then
    local inst = mod.get(namespace)
    if not inst then
      notify.warn(("no telemetry instance for namespace %q"):format(namespace))
      return
    end
    list = { inst }
  end

  if #list == 0 then
    notify.info("no telemetry instances -- nothing to reset")
    return
  end

  -- Flush BEFORE deciding `any_existing`, same reasoning `do_setup_all`
  -- gives for its own candidate loop: calls already collected but not yet
  -- flushed to disk must count as "existing data" too, or a backup taken
  -- right after would silently miss them.
  local any_existing = false
  for _, inst in ipairs(list) do
    inst.flush()
    local existing = mod.load(inst.namespace, inst._cache_opts)
    if existing and next(existing.functions or {}) ~= nil then
      any_existing = true
      break
    end
  end

  ---@param backup_dir string|nil
  local function proceed(backup_dir)
    local backed_up = 0
    for _, inst in ipairs(list) do
      if backup_dir then
        local existing = mod.load(inst.namespace, inst._cache_opts)
        if existing and next(existing.functions or {}) ~= nil then
          if setup_all.write_backup(backup_dir, inst.namespace, existing) then
            backed_up = backed_up + 1
          end
        end
      end
      inst.reset()
    end

    notify.info(
      ("collected data cleared for %d instance(s)%s"):format(
        #list,
        backed_up > 0 and (", backed up %d with existing data to %s"):format(backed_up, backup_dir)
          or ""
      )
    )
  end

  if not any_existing then
    proceed(nil)
    return
  end

  prompt_backup_dir(proceed, function()
    notify.warn("reset aborted -- existing telemetry data left untouched")
  end)
end

---Register `:RATelemetry`. Idempotent (`usercmd.create` defaults to `force`).
function M.setup()
  usercmd.create("RATelemetry", function(args)
    local mod = telemetry()
    local first = args.fargs[1]
    local rest = args.fargs[2]

    if first == "reset" then
      -- Its own branch, not folded into start/stop below: unlike those two,
      -- a reset may prompt for a backup directory first (`do_reset_all`),
      -- and that async-ish confirm flow doesn't fit the other two's
      -- immediate-and-done shape.
      do_reset_all(rest)
    elseif first == "start" or first == "stop" then
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
        else
          inst.stop()
          -- Naming the file, because `stop` is where "is it saved?" gets
          -- asked and a path answers it outright. `stop` flushes.
          notify.info(("stopped %s — written to %s"):format(rest, inst.data_path()))
        end
        return
      end

      if first == "start" then
        notify.info(("started %d instance(s)"):format(mod.start_all()))
      else
        notify.info(
          ("stopped %d instance(s), each written to its cache file"):format(mod.stop_all())
        )
      end
    elseif first == "flush" then
      -- Write now, keep recording. The periodic flush already does this
      -- every `flush_interval_ms`, and `stop`/`VimLeavePre` do it too — so
      -- this command buys one thing only: certainty at a chosen moment,
      -- without ending the run to get it. That is worth a command name
      -- because the alternative people actually reach for is `stop`, which
      -- costs them the wrappers and the session's continuity.
      if rest and rest ~= "" then
        local inst = mod.get(rest)
        if not inst then
          notify.warn(("no telemetry instance for namespace %q"):format(rest))
          return
        end
        if inst.flush() then
          notify.info(("flushed %s — %s"):format(rest, inst.data_path()))
        else
          notify.error(("could not write %s"):format(inst.data_path()))
        end
        return
      end

      -- `mod.flush_all()` exists and is deliberately not used here: it
      -- returns only the number that succeeded, so "no instance is running"
      -- and "every write failed" both come back as 0. For a command whose
      -- entire job is confirming that a write happened, those are the two
      -- answers that must not be spelled the same.
      local written, failed = 0, 0
      for _, inst in ipairs(mod.instances()) do
        if inst.flush() then
          written = written + 1
        else
          failed = failed + 1
        end
      end
      if written == 0 and failed == 0 then
        notify.warn("no live telemetry instance to flush")
      elseif failed > 0 then
        notify.error(("flushed %d instance(s), %d could not be written"):format(written, failed))
      else
        notify.info(("flushed %d instance(s)"):format(written))
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
    elseif first == "status" then
      -- One compact block per namespace this plugin knows about — live this
      -- session or only ever persisted — rather than `report`'s own
      -- function-by-function dump of every instance at once. Answers "which
      -- repos are recording, in what mode, and is there anything on disk
      -- worth reading", the whole-fleet question `report` was never
      -- shaped to answer quickly once more than a couple of namespaces
      -- exist. `<CR>` still reaches the full per-function report for the
      -- namespace under the cursor, the same drilldown every other
      -- multi-instance view already offers.
      local report_mod_ = require("runtime-analysis.telemetry.report")
      local by_ns = {}

      local function build()
        local rows = mod.status_reports({ report_opts = { sort = "calls" } })
        by_ns = {}
        for _, row in ipairs(rows) do
          by_ns[row.report.namespace] = row
        end
        return report_mod_.status_lines(rows)
      end

      show(build(), "runtime-analysis.telemetry — status", {
        on_refresh = build,
        on_drilldown = function(ns)
          local row = by_ns[ns]
          if not row then
            return nil
          end
          return report_mod_.lines(row.report), ("runtime-analysis.telemetry — %s"):format(ns)
        end,
      })
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
      -- Namespace-free on purpose: this measures
      -- module loads, not one namespace's wrapped functions, so the
      -- second slot every other subcommand uses for a namespace is a
      -- `top` count here instead.
      local startup = require("runtime-analysis.telemetry.startup")
      show(
        startup.lines(startup.report({ top = tonumber(rest) or 40 })),
        "runtime-analysis.telemetry — startup"
      )
    elseif first == "flamegraph" then
      -- Namespace-free for the same reason `startup` above is: this draws
      -- module loads, of which a session has exactly one set. `rest` is
      -- therefore an output path rather than a namespace -- pass one to keep
      -- the file (next to a ticket, in a repo), leave it out and it lands in
      -- the disposable cache directory beside the other reports.
      local startup = require("runtime-analysis.telemetry.startup")
      local flamegraph = require("runtime-analysis.telemetry.renderers.flamegraph")
      local report = startup.report()

      if #(report.order or {}) == 0 then
        notify.warn(
          "no startup data recorded — telemetry.startup.autostart() has to run before the "
            .. "modules you want to see (see its own docs for where that line belongs)"
        )
        return
      end

      local path = (rest and rest ~= "") and vim.fn.fnamemodify(vim.fn.expand(rest), ":p")
        or report_file.flamegraph_path()
      local ok_write, err = report_file.write(path, { flamegraph.svg(report) })
      if not ok_write then
        notify.error("failed to write flamegraph: " .. tostring(err))
        return
      end

      -- images.nvim first, and only as a soft dependency: it draws the SVG
      -- in the terminal through its own cached SVG->PNG conversion, which is
      -- the whole reason this renderer emits SVG. Without it the file still
      -- exists and the system opener still shows it -- the graphic is the
      -- deliverable, the viewer is a convenience.
      local ok_images, images = pcall(require, "images")
      if ok_images and type(images.show) == "function" and images.show(path) then
        notify.info("wrote " .. path)
        return
      end

      local ok_open = pcall(function()
        require("lib.nvim.fs.open.url.system_opener").open(path)
      end)
      notify.info(
        ok_open and ("wrote and opened " .. path)
          or ("wrote " .. path .. " — open it yourself, no system opener available")
      )
    elseif first == "cost" then
      -- No arguments: this is inherently cross-
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
      local report_show_opts = {
        on_refresh = function()
          if namespace and namespace ~= "" then
            local inst = mod.get(namespace)
            if inst then
              inst.flush()
            end
          else
            for _, inst in ipairs(mod.instances()) do
              inst.flush()
            end
          end
          return report_lines({ sort = "calls", top = 40 }, namespace)
        end,
      }
      -- Same reasoning as open_report's dispatch: a single-namespace view's
      -- only header row is already itself, so drilldown is only offered on
      -- the bare "every instance" report.
      if not namespace or namespace == "" then
        report_show_opts.on_drilldown = function(ns)
          local inst = mod.get(ns)
          if not inst then
            return nil
          end
          inst.flush()
          return inst.lines(), ("runtime-analysis.telemetry — %s"):format(ns)
        end
      end
      show(
        report_lines({ sort = "calls", top = 40 }, namespace),
        "runtime-analysis.telemetry",
        report_show_opts
      )
    end
  end, {
    nargs = "*",
    desc = "runtime-analysis.telemetry: report|status|start|stop|reset|disable|enable|disabled|coverage|export|export-all|open|compare|startup|cost|snapshot|snapshots|snapshot-compare|setup|full [namespace] [days]",
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

  usercmd.create("RATelemetryResetAll", function()
    do_reset_all(nil)
  end, {
    desc = "runtime-analysis.telemetry: reset every live instance, prompting once for a backup "
      .. "directory if anything would be lost (same as :RATelemetry reset)",
  })

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
