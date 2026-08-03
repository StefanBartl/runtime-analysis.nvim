---@module 'runtime-analysis.bindings.usrcmds'
--- Registers `:RARequest` and `:RASend` — split out of `init.lua` into its
--- own `bindings/` module to match the `bindings/{keymaps,usrcmds,autocmds}.lua`
--- shape every sibling plugin uses. `:RATelemetry` is not registered here: it
--- is deliberately opt-in on its own terms (see
--- `telemetry/command.lua`'s doc comment), called separately from `setup()`.
---
--- No `keymaps.lua` or `autocmds.lua` sit beside this file: this plugin sets
--- zero default keymaps and zero autocmds, by design — every entry point is a
--- command, the same "no global keymaps at all" choice documentation.nvim's
--- own `:DocBrowse` keymap sheet documents for the identical reason (a request
--- buffer's own edits are what drive this plugin, not a keybinding). An empty
--- placeholder file for either would be scaffolding with nothing to scaffold.

local M = {}

---Parse the current buffer as a request and send it, showing the response
---in the split `view.lua` manages.
---@param ra RA
local function send_current_buffer(ra)
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local request, err = require("runtime-analysis.parse").parse(lines)
  if not request then
    vim.notify("runtime-analysis: " .. err, vim.log.levels.ERROR)
    return
  end

  local resp_lines, run_err = require("runtime-analysis.runner").run(request)
  if not resp_lines then
    vim.notify("runtime-analysis: " .. run_err, vim.log.levels.ERROR)
    return
  end

  require("runtime-analysis.view").show(resp_lines, { split = ra.opts.split })
end

---@param ra RA The plugin's own module table — read for `ra.opts` and called
---back into for `ra.open_request` so both commands stay in sync with a
---`setup()` that has already run.
function M.setup(ra)
  vim.api.nvim_create_user_command("RARequest", function()
    ra.open_request()
  end, {
    desc = "Open a new HTTP request buffer",
  })
  vim.api.nvim_create_user_command("RASend", function()
    send_current_buffer(ra)
  end, {
    desc = "Send the current buffer as an HTTP request",
  })
end

return M
