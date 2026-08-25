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

  -- `telemetry` is the fourth accepted option (see `KNOWN_OPTS` in
  -- `runtime-analysis.init`), and it deliberately has **no default here**.
  -- Auto-instrumentation is opt-in: the absence of the key is what means "do
  -- not instrument", exactly as if `telemetry.auto()` were never called. A
  -- default table would switch it on for everyone who never asked.
  --
  -- Its own defaults — retention_days, flush_interval_ms, max_arg_values,
  -- persist — live with the implementation, in
  -- `runtime-analysis.telemetry`, and apply once a caller passes the key.
  -- Named here so this file is a complete answer to "what does setup()
  -- accept", which it was not while the option existed only in the type
  -- annotation.
}

return M
