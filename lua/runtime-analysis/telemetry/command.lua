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
---   :RATelemetry export [path]   write a snapshot (JSON, or Markdown if path ends .md)
---   :RATelemetry open [ns]       render + open externally (report_style: auto/kit/mdview/file)

local usercmd = require("lib.nvim.usercmd")
local notify = require("lib.nvim.notify").create("[runtime-analysis.telemetry]")
local report_file = require("runtime-analysis.telemetry.report_file")
local resolve_report_style = require("runtime-analysis.telemetry.report_style")
local telemetry_config = require("runtime-analysis.telemetry.config")
local mdview_renderer = require("runtime-analysis.telemetry.renderers.mdview")

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
  "open",
  "compare",
}

---@return RA.Telemetry
local function telemetry()
  return require("runtime-analysis.telemetry")
end

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

---@param path string|nil
---@return string|nil written
local function export(path)
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
  if target:sub(-3):lower() == ".md" then
    local ok = report_file.write(target, mod.markdown_all())
    return ok and target or nil
  end

  local payload = { exported_at = os.time(), reports = mod.report_all() }

  local ok, encoded = pcall(vim.json.encode, payload)
  if not ok then
    return nil
  end

  local file = io.open(target, "w")
  if not file then
    return nil
  end
  file:write(encoded)
  file:close()
  return target
end

---`:RATelemetry open [ns]` — render + hand the report to whatever
---`report_style` resolves to. Always forces a flush first: the honest-limits
---note in the roadmap doc is explicit that the browser shows the *last*
---flush, and `open` is the one moment that promise should hold as tightly as
---possible.
---@param namespace string|nil
local function open_report(namespace)
  local mod = telemetry()
  local style = resolve_report_style(telemetry_config.report_style())

  ---@param lines string[]
  ---@param path string
  ---@param kit_lines string[]
  ---@param title string
  local function dispatch(lines, path, kit_lines, title)
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
      ("runtime-analysis.telemetry — %s"):format(namespace)
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
    "runtime-analysis.telemetry"
  )
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
        local n = 0
        for _, inst in ipairs(mod.instances()) do
          if inst.start() then
            n = n + 1
          end
        end
        notify.info(("started %d instance(s)"):format(n))
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
      local written = export(rest)
      if written then
        notify.info("wrote " .. written)
      else
        notify.error("export failed")
      end
    elseif first == "open" then
      open_report(rest)
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
    desc = "runtime-analysis.telemetry: report|start|stop|reset|disable|enable|disabled|coverage|export|open|compare [namespace] [days]",
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
end

M.SUBCOMMANDS = SUBCOMMANDS

return M
