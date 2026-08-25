-- probe/startup.lua — measure a Neovim startup from before the config runs.
--
--   nvim --cmd "luafile /path/to/runtime-analysis.nvim/probe/startup.lua" <file>
--
-- `:RA startup probe` prints that line with the path already filled in.
--
-- Why a separate file at all: the stall timer has to tick BEFORE the config
-- is sourced, and at that point nothing has set up a plugin manager, so
-- `require("runtime-analysis.startup")` cannot resolve yet. This file puts the
-- plugin's own `lua/` on `package.path` — derived from where this file itself
-- lives, so it works from any checkout without configuration — and then hands
-- straight over to the real module. All the logic lives there; this is only
-- the bootstrap.
--
-- Everything is overridable from the command line, e.g. a 30s window that
-- reports only blocks of 200ms or more:
--
--   nvim --cmd "lua vim.g.ra_startup = { duration_ms = 30000, stall_ms = 200 }" \
--        --cmd "luafile .../probe/startup.lua" <file>

local src = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(src, ":h:h")

package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  package.path,
}, ";")

local ok, startup = pcall(require, "runtime-analysis.startup")
if not ok then
  vim.notify(
    "[runtime-analysis] startup probe: could not load the module from "
      .. root
      .. "\n"
      .. tostring(startup),
    vim.log.levels.ERROR
  )
  return
end

local opts = type(vim.g.ra_startup) == "table" and vim.g.ra_startup or {}
startup.start(opts)
