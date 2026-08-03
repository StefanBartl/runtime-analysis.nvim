---@module 'runtime-analysis.config'
--- Configuration entry point — re-exports the defaults in
--- [`DEFAULTS.lua`](DEFAULTS.lua). Split into its own directory (rather than
--- a single `config.lua`) to match the `config/init.lua` + `config/DEFAULTS.lua`
--- shape every sibling plugin uses; `require("runtime-analysis.config")`
--- resolves to this file exactly as it resolved to the old single file, so
--- nothing at either call site had to change.
---
--- There is no `build()` here the way documentation.nvim's config module has
--- one: that split exists because documentation.nvim derives several options
--- from `root` (source dir, title, …). This plugin's options are not derived
--- from anything — `setup()` in `init.lua` merges the caller's `opts` directly
--- over `DEFAULTS` — so a resolver function here would have nothing to do.

local M = {}

M.DEFAULTS = require("runtime-analysis.config.DEFAULTS").DEFAULTS

return M
