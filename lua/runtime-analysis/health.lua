---@module 'runtime-analysis.health'
--- `:checkhealth runtime-analysis`.
---
--- Scoped to what actually breaks a command silently rather than every
--- theoretical gap: `curl` missing turns `:RASend` into a confusing "request
--- failed" with no obvious cause; `lib.nvim` missing is a hard failure on
--- `require` this plugin cannot recover from; mdview absent only degrades one
--- `report_style` value, so it is reported, not erred. Same posture
--- documentation.nvim's own `editor/health.lua` uses, mirrored here rather
--- than reinvented.

local M = {}

local H = vim.health or {}
local h_start = H.start or H.report_start
local h_ok = H.ok or H.report_ok
local h_warn = H.warn or H.report_warn
local h_error = H.error or H.report_error
local h_info = H.info or H.report_info

local MIN_NVIM = { 0, 10, 0 }

---The lib.nvim modules this plugin actually requires — as module paths
---rather than one `lib.nvim` probe, so a missing piece is named rather than
---only "something is missing". See the README's own Dependencies section for
---which feature needs which.
---@type string[]
local DEPS = {
  "lib.nvim.net.curl",
  "lib.nvim.cache.disk",
  "lib.nvim.fs.project_key",
  "lib.nvim.fs.find_root",
  "lib.nvim.fs.json",
  "lib.nvim.git",
  "lib.nvim.usercmd",
  "lib.nvim.usercmd.composer",
  "lib.nvim.notify",
  "lib.nvim.autocmd",
}

---@internal
---@return boolean
local function version_ok()
  local v = vim.version()
  if v.major ~= MIN_NVIM[1] then
    return v.major > MIN_NVIM[1]
  end
  if v.minor ~= MIN_NVIM[2] then
    return v.minor > MIN_NVIM[2]
  end
  return v.patch >= MIN_NVIM[3]
end

-- Duplicated from `telemetry/init.lua` rather than required from it: that
-- constant is local there on purpose (an internal default, not a public
-- one), and requiring the whole module just to read one path string would
-- pull its `vim.uv`/`cache.disk` setup into a health check that must still
-- report *something* useful when those very dependencies are the problem.
local DEFAULT_TELEMETRY_CACHE_DIR = vim.fn.stdpath("cache") .. "/runtime-analysis.nvim/cache"

function M.check()
  h_start("runtime-analysis.nvim: environment")

  local v = vim.version()
  local vstr = ("%d.%d.%d"):format(v.major, v.minor, v.patch)
  if version_ok() then
    h_ok(("Neovim %s (>= %d.%d.%d)"):format(vstr, MIN_NVIM[1], MIN_NVIM[2], MIN_NVIM[3]))
  else
    h_warn(
      ("Neovim %s is older than the required %d.%d.%d"):format(
        vstr,
        MIN_NVIM[1],
        MIN_NVIM[2],
        MIN_NVIM[3]
      ),
      { "The request runner uses vim.system; telemetry uses vim.uv.hrtime." }
    )
  end

  if vim.fn.executable("curl") == 1 then
    h_ok("curl on PATH — required by :RASend")
  else
    h_error("curl not on PATH", {
      "lib.nvim.net.curl shells out to curl for every request.",
      ":RASend will fail on every send until curl is installed.",
    })
  end

  h_start("runtime-analysis.nvim: lib.nvim")

  local missing = {}
  for _, mod in ipairs(DEPS) do
    if not pcall(require, mod) then
      missing[#missing + 1] = mod
    end
  end
  if #missing == 0 then
    h_ok(("all %d required lib.nvim modules load"):format(#DEPS))
  else
    h_error(("%d of %d lib.nvim modules failed to load"):format(#missing, #DEPS), {
      "Missing: " .. table.concat(missing, ", "),
      "lib.nvim is a hard dependency: https://github.com/StefanBartl/lib.nvim",
      'Add it to this plugin\'s spec: dependencies = { "StefanBartl/lib.nvim" }',
    })
  end

  h_start("runtime-analysis.nvim: telemetry")

  local ok_telemetry, telemetry = pcall(require, "runtime-analysis.telemetry")
  if ok_telemetry then
    local names = {}
    for _, inst in ipairs(telemetry.instances()) do
      names[#names + 1] = inst.namespace
    end
    table.sort(names)
    if #names == 0 then
      h_info("no live telemetry instances in this session")
    else
      h_ok(("%d live instance(s): %s"):format(#names, table.concat(names, ", ")))
    end

    local disabled = telemetry.disabled()
    if disabled and #disabled > 0 then
      h_info(("persistently disabled: %s"):format(table.concat(disabled, ", ")))
    end
  else
    h_warn("runtime-analysis.telemetry failed to load", { tostring(telemetry) })
  end
  h_info("default cache dir: " .. DEFAULT_TELEMETRY_CACHE_DIR)
  if vim.fn.isdirectory(DEFAULT_TELEMETRY_CACHE_DIR) == 1 then
    local writable = vim.fn.filewritable(DEFAULT_TELEMETRY_CACHE_DIR) == 2
    if writable then
      h_ok("cache directory exists and is writable")
    else
      h_warn("cache directory exists but is not writable", {
        "Telemetry persistence (`persist = true`, the default) needs this.",
      })
    end
  else
    h_info("cache directory does not exist yet — created on first flush")
  end

  h_start("runtime-analysis.nvim: request history")

  local ok_history, history = pcall(require, "runtime-analysis.history")
  if ok_history then
    local ok_list, entries = pcall(history.list)
    if ok_list then
      h_ok(("%d entr%s for this project"):format(#entries, #entries == 1 and "y" or "ies"))
    else
      h_warn("failed to read this project's history", { tostring(entries) })
    end
  else
    h_warn("runtime-analysis.history failed to load", { tostring(history) })
  end

  h_start("runtime-analysis.nvim: environments")

  local ok_env, env = pcall(require, "runtime-analysis.env")
  if ok_env then
    local ok_names, names = pcall(env.list_names)
    if ok_names then
      if #names == 0 then
        h_info(
          ("no environments defined — create %s at the project root"):format(env.SHARED_FILE)
        )
      else
        h_ok(("%d defined: %s"):format(#names, table.concat(names, ", ")))
      end
      h_info("active: " .. (env.current() or "none selected — :RA env <name>"))
    else
      h_warn("failed to read this project's environment files", { tostring(names) })
    end
  else
    h_warn("runtime-analysis.env failed to load", { tostring(env) })
  end

  h_start("runtime-analysis.nvim: keymap/command usage")

  local ok_usage, usage = pcall(require, "runtime-analysis.usage")
  if ok_usage then
    if usage.is_running() then
      local report = usage.report()
      h_ok(
        ("tracking — %d mapping(s)/command(s) seen, %d press(es) total"):format(
          report.wrapped,
          report.total_calls
        )
      )
    else
      h_info("not tracking — opt-in, :RA usage start to begin")
    end
  else
    h_warn("runtime-analysis.usage failed to load", { tostring(usage) })
  end

  h_start("runtime-analysis.nvim: optional tools")

  local ok_mdview = pcall(require, "mdview")
  if ok_mdview then
    h_ok('mdview.nvim — report_style "auto"/"mdview" can open a live browser report')
    h_ok('mdview.nvim — report_style "preview-tab" can open an in-editor report tab')
  else
    h_info("mdview.nvim not installed", {
      'report_style "auto" and "preview-tab" both fall back to the in-editor kit float.',
      "Everything else (:RARequest, :RASend, :RATelemetry) works without it.",
    })
  end

  local ok_kit = pcall(require, "lib.nvim.ui.kit")
  if not ok_kit then
    h_info("lib.nvim.ui.kit not available — :RATelemetry's report float falls back to :messages")
  end

  local ok_pp, pdfport = pcall(require, "pdfport")
  if ok_pp and type(pdfport.can_create) == "function" and pdfport.can_create("markdown") then
    h_ok("pdfport.nvim — :RATelemetry export report.pdf can be written")
  elseif ok_pp then
    h_info("pdfport.nvim installed, but no markdown producer is available", {
      ":RATelemetry export report.pdf would fail until pandoc + a PDF engine",
      "are installed. See pdfport.nvim's :checkhealth for which is missing.",
    })
  else
    h_info("pdfport.nvim not installed", {
      "Only :RATelemetry export report.pdf needs it; .md and .json export",
      "work without it. https://github.com/StefanBartl/pdfport.nvim",
    })
  end

  local ok_progress = pcall(require, "lib.nvim.progress")
  if ok_progress then
    h_ok("lib.nvim.progress — :RA send shows a sending/cancel indicator")
  else
    h_info("lib.nvim.progress not available", {
      ":RA send still works asynchronously without it, just with no visible",
      "indicator; :RA cancel still discards the result directly.",
    })
  end

  h_start("runtime-analysis.nvim: commands")
  -- All four are registered unconditionally by `require("runtime-analysis")
  -- .setup()` — nothing here is independently opt-in the way `telemetry`'s
  -- own auto-instrumentation is (that is the `opts.telemetry` check above).
  local cmds = vim.api.nvim_get_commands({})
  if cmds.RA and cmds.RARequest and cmds.RASend and cmds.RATelemetry then
    h_ok(":RA, :RARequest, :RASend, :RATelemetry are registered")
  else
    h_info("setup() has not run yet in this session — no commands registered")
  end

  -- runtime-analysis.nvim's own docs/install.json via lib.nvim.deps — the
  -- same curl check above, but with its declared `why` and a pointer to
  -- `:Lib deps show`. Does nothing if lib.nvim.deps is unavailable (older
  -- lib.nvim).
  local ok_deps, deps_health = pcall(require, "lib.nvim.deps.health")
  if ok_deps then
    h_start("runtime-analysis.nvim: declared tools (lib.nvim.deps)")
    deps_health.report_for("runtime-analysis.nvim")
  end
end

return M
