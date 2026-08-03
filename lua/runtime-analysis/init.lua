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
---
--- `M.open_request` is this plugin's one public integration surface for
--- another plugin to build on — `docs/ECOSYSTEM.md` §7 states the rule this
--- follows explicitly: "the join should be written against a small named
--- interface from the start", not against this module's internal file
--- layout. documentation.nvim's Endpoints browser mode (step 6) is the
--- first consumer: a route found by static analysis has a path but no base
--- URL and no real values for any `:param` in it — genuinely nothing this
--- plugin could send correctly on its own — so the integration hands the
--- method and path over pre-filled and lets the reader complete the
--- request before sending it themselves, rather than guessing at either.

local M = {}

local DEFAULTS = require("runtime-analysis.config").DEFAULTS

---@type { split: string, request_filetype: string }
M.opts = vim.deepcopy(DEFAULTS)

---Open a new request buffer. With no `lines`, pre-filled with a template —
---the shape a reader needs to see to know what to fill in, the same reason
---a fresh `.http`/`.rest` file in either sibling tool starts non-empty. With
---`lines`, that content is used instead — what `documentation.nvim`'s
---Endpoints mode hands over (`METHOD path`, blank line), leaving the base
---URL and any path params for the reader to fill in before `:RASend`.
---@param lines string[]?
function M.open_request(lines)
  vim.cmd("enew")
  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].buftype = "acwrite"
  vim.bo[bufnr].filetype = M.opts.request_filetype
  lines = lines or { "GET https://", "" }
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  -- End of the first line, not a hardcoded column: `lines` may not be the
  -- default template, and a cursor position tuned for "GET https://"
  -- would land mid-word on anything else.
  vim.api.nvim_win_set_cursor(0, { 1, #lines[1] })
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

  vim.api.nvim_create_user_command("RARequest", function()
    M.open_request()
  end, {
    desc = "Open a new HTTP request buffer",
  })
  vim.api.nvim_create_user_command("RASend", send_current_buffer, {
    desc = "Send the current buffer as an HTTP request",
  })
end

return M
