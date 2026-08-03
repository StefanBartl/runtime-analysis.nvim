-- scripts/telemetry.lua — read a namespace's telemetry off disk, no editor
-- session and no live instance required.
--
-- `telemetry.load()` already does the reading part (it was built for
-- exactly this — a fresh process joining against a previous session's
-- counts, the motivating case being documentation.nvim's dead-function
-- check), and `report.build()` already turns raw `Data` into the same
-- report shape `:RATelemetry`'s live-instance path renders. This script is
-- the argument parser around both, not new analysis (see docs/ROADMAP.md
-- §4.1).
--
-- Usage:
--   nvim --headless -l scripts/telemetry.lua report <namespace> [opts]
--   nvim --headless -l scripts/telemetry.lua export <namespace> <path> [opts]
--
-- opts:
--   --since=7d|24h|2w|<days>   only calls within this window
--   --top=N                    only the N busiest entries
--   --sort=calls|name|time     default: calls
--   --dir=<path>               cache dir override (default: the plugin's own)
--
-- `export`'s format is inferred from <path>'s own extension — `.md` writes
-- Markdown, anything else writes JSON — the same rule `:RATelemetry export`
-- already uses, so there is one rule to remember rather than one per
-- entry point.
--
-- Deliberately not a `coverage` subcommand: "which registered functions
-- were never called" needs to know the *registered* set, which only a live
-- instance's own `wrap()` calls establish — `telemetry.load()` has no way
-- to answer that cold, so promising it here would be a lie the CLI could
-- not back up.

-- Make the repo importable, and find lib.nvim — the same three-candidate
-- search `docs/TESTS/run.lua` uses (CI's `.deps/lib.nvim` checkout, a local
-- sibling checkout, or an already-active plugin manager), duplicated rather
-- than shared: this is a second, independent entry point, and the block is
-- small enough that a shared helper module would cost more indirection than
-- it saves for two call sites.
vim.opt.rtp:append(vim.fn.getcwd())

local function add_lib_nvim()
  if pcall(require, "lib.nvim.cache.disk") then
    return
  end
  local candidates = {}
  if vim.env.LIB_NVIM_DIR and vim.env.LIB_NVIM_DIR ~= "" then
    candidates[#candidates + 1] = vim.env.LIB_NVIM_DIR
  end
  candidates[#candidates + 1] = vim.fn.getcwd() .. "/.deps/lib.nvim"
  candidates[#candidates + 1] = vim.fs.dirname(vim.fn.getcwd()) .. "/lib.nvim"
  for _, dir in ipairs(candidates) do
    if dir and vim.fn.isdirectory(dir) == 1 then
      vim.opt.rtp:append(dir)
      if pcall(require, "lib.nvim.cache.disk") then
        return
      end
    end
  end
  io.stderr:write("scripts/telemetry.lua: lib.nvim not found.\n")
  io.stderr:write("  Set LIB_NVIM_DIR, or clone it to .deps/lib.nvim, or beside this repo.\n")
  os.exit(1)
end

add_lib_nvim()

---@param s string
local function die(s)
  io.stderr:write(s, "\n")
  os.exit(1)
end

---Parse `--name=value` / `--name` flags out of `argv[from..]`, leaving
---positionals. Takes a start index rather than a pre-sliced table: `arg`
---(what `nvim -l script.lua ...` populates) is Lua-5.1-shaped here —
---`table.unpack` does not exist on this Neovim's bundled LuaJIT even though
---the global `unpack` does — so slicing it via `{ select(2,
---table.unpack(argv)) }` is not portable. Iterating from an index sidesteps
---the question entirely.
---@param argv string[]
---@param from integer
---@return string[] positionals
---@return table<string, string|boolean> flags
local function split_flags(argv, from)
  local positionals, flags = {}, {}
  for i = from, #argv do
    local arg = argv[i]
    local name, value = arg:match("^%-%-([%w_]+)=(.*)$")
    if name then
      flags[name] = value
    else
      local bare = arg:match("^%-%-([%w_]+)$")
      if bare then
        flags[bare] = true
      else
        positionals[#positionals + 1] = arg
      end
    end
  end
  return positionals, flags
end

---@param flags table<string, string|boolean>
---@return RA.Telemetry.ReportOpts
local function report_opts(flags)
  local opts = {}
  if type(flags.since) == "string" then
    opts.since = flags.since
  end
  if type(flags.top) == "string" then
    opts.top = tonumber(flags.top)
  end
  if type(flags.sort) == "string" then
    opts.sort = flags.sort
  end
  return opts
end

---@param flags table<string, string|boolean>
---@return Lib.Cache.Opts|nil
local function cache_opts(flags)
  if type(flags.dir) == "string" and flags.dir ~= "" then
    return { dir = flags.dir }
  end
  return nil
end

---Load `namespace`'s data and build a report from it — the shared step
---both subcommands need. Dies with a clear message when nothing was ever
---persisted, rather than rendering an empty report that looks like "zero
---calls" instead of "never collected" (see `telemetry.load()`'s own
---doc-comment on why those two are kept distinguishable).
---@param namespace string
---@param flags table<string, string|boolean>
---@return RA.Telemetry.Report
local function load_report(namespace, flags)
  local telemetry = require("runtime-analysis.telemetry")
  local report = require("runtime-analysis.telemetry.report")
  local opts = cache_opts(flags)

  local data = telemetry.load(namespace, opts)
  if not data then
    die(("no persisted telemetry for namespace %q"):format(namespace))
  end
  ---@cast data -nil

  local meta = {
    running = false, -- a cold read: nothing here is live
    disabled = telemetry.is_disabled(namespace),
    wrapped = 0, -- unknown without a live instance's own wrap() calls
    modes = {},
  }
  return report.build(namespace, data, meta, report_opts(flags))
end

local argv = _G.arg or {}
local action = argv[1]

if action == "report" then
  local positionals, flags = split_flags(argv, 2)
  local namespace = positionals[1]
  if not namespace then
    die(
      "usage: telemetry.lua report <namespace> [--since=7d] [--top=N] [--sort=calls|name|time] [--dir=path]"
    )
  end
  local report = require("runtime-analysis.telemetry.report")
  local built = load_report(namespace, flags)
  io.stdout:write(table.concat(report.lines(built), "\n"), "\n")
elseif action == "export" then
  local positionals, flags = split_flags(argv, 2)
  local namespace, path = positionals[1], positionals[2]
  if not namespace or not path then
    die(
      "usage: telemetry.lua export <namespace> <path> [--since=7d] [--top=N] [--sort=calls|name|time] [--dir=path]"
    )
  end
  ---@cast namespace -nil
  ---@cast path -nil
  local report = require("runtime-analysis.telemetry.report")
  local built = load_report(namespace, flags)

  if path:sub(-3):lower() == ".md" then
    local report_file = require("runtime-analysis.telemetry.report_file")
    local ok, err = report_file.write(path, report.markdown(built))
    if not ok then
      die("failed to write " .. path .. ": " .. tostring(err))
    end
  else
    local ok_encode, encoded = pcall(vim.json.encode, built)
    if not ok_encode then
      die("failed to encode report as JSON: " .. tostring(encoded))
    end
    ---@cast encoded -nil
    local file = io.open(path, "w")
    if not file then
      die("failed to open " .. path .. " for writing")
    end
    ---@cast file -nil
    file:write(encoded)
    file:close()
  end
  io.stdout:write("wrote ", path, "\n")
else
  die("usage: telemetry.lua {report|export} <namespace> [...opts]")
end
