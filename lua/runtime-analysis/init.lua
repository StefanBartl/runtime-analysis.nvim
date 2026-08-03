---@module 'runtime-analysis'
--- runtime-analysis.nvim: runtime truth, paired with documentation.nvim's
--- static truth — see that plugin's `docs/ECOSYSTEM.md` for the full split.
---
--- This plugin's first feature (`docs/ECOSYSTEM.md` step 5): an in-editor
--- HTTP request runner. `:RARequest` opens a new request buffer (one
--- request per buffer, `METHOD url` on the first line, `Name: value`
--- headers, a blank line, then an optional body — the same shape VS Code's
--- REST Client / IntelliJ's HTTP Client already use). `:RASend`, run from
--- inside that buffer, parses it, sends it via `lib.nvim.net.curl`, and
--- shows the response in a persistent split beside it.
---
--- No browser, no server, no CORS, no token — the cheap first version
--- `docs/ECOSYSTEM.md` calls for specifically, because none of those
--- problems exist for a request Neovim itself sends.

local M = {}

local DEFAULTS = require("runtime-analysis.config").DEFAULTS

---@type { split: string, request_filetype: string }
M.opts = vim.deepcopy(DEFAULTS)

---Open a new request buffer, pre-filled with a template — the shape a
---reader needs to see to know what to fill in, the same reason a fresh
---`.http`/`.rest` file in either sibling tool starts non-empty.
local function open_request_buffer()
  vim.cmd("enew")
  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].buftype = "acwrite"
  vim.bo[bufnr].filetype = M.opts.request_filetype
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "GET https://",
    "",
  })
  vim.api.nvim_win_set_cursor(0, { 1, 12 })
end

---Parse the current buffer as a request and send it, showing the response
---in the split `view.lua` manages.
local function send_current_buffer()
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

  require("runtime-analysis.view").show(resp_lines, { split = M.opts.split })
end

---Plugin entry point.
---@param opts? { split?: string, request_filetype?: string }
function M.setup(opts)
  M.opts = vim.tbl_deep_extend("force", vim.deepcopy(DEFAULTS), opts or {})

  vim.api.nvim_create_user_command("RARequest", open_request_buffer, {
    desc = "Open a new HTTP request buffer",
  })
  vim.api.nvim_create_user_command("RASend", send_current_buffer, {
    desc = "Send the current buffer as an HTTP request",
  })
end

return M
