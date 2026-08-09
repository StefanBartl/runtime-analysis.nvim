---@module 'runtime-analysis.config.DEFAULTS'
--- Plugin-side defaults, as data — same shape documentation.nvim's own
--- `config/DEFAULTS.lua` uses, kept this small because there is not much to
--- configure yet.

local M = {}

---@type { split: string, request_filetype: string }
M.DEFAULTS = {
  -- Where the response pane opens relative to the request buffer.
  split = "vsplit",
  -- Filetype set on a new `:RARequest` buffer — `http` rather than a
  -- plugin-specific name, since VS Code's REST Client / IntelliJ's HTTP
  -- Client already claim it and this buffer's own syntax matches theirs;
  -- a reader's existing syntax highlighting for either tool works here
  -- unmodified.
  request_filetype = "http",

  -- One-time "which CLI tools does this plugin want, and why" popup on
  -- first setup() after install (via lib.nvim.deps). false disables it for
  -- this plugin specifically, right here in the spec passed to setup() —
  -- no vim.g needed. See README.
  deps_popup = true,
}

return M
