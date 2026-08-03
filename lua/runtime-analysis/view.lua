---@module 'runtime-analysis.view'
--- The response pane: a persistent vertical split, reused across sends
--- rather than a new window every time. Deliberately not
--- `lib.nvim.ui.kit`'s `viewer`/`surface` components — those are floats
--- that close as soon as focus leaves them, which is exactly wrong here:
--- `docs/ECOSYSTEM.md`'s own description is "a Neovim split holding a
--- request buffer and a response buffer", because the whole workflow is
--- look at the response, go back to the request buffer to tweak it, send
--- again — a float that vanishes the moment you look away from it fights
--- that instead of serving it.

local M = {}

local BUFNAME = "runtime-analysis://response"

---The response buffer, creating it if it does not exist yet. Named and
---looked up by name rather than kept in a module-level variable, so a
---`:bwipeout` or a fresh `:source` of this file during development does not
---leave a stale, invalid bufnr behind — `vim.fn.bufnr` always answers
---against what Neovim itself currently has.
---@return integer bufnr
local function ensure_buffer()
  local bufnr = vim.fn.bufnr(BUFNAME)
  if bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) then
    return bufnr
  end
  bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, BUFNAME)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "runtime-analysis-response"
  return bufnr
end

---The window currently showing the response buffer, or `nil`.
---@param bufnr integer
---@return integer? winid
local function find_window(bufnr)
  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(winid) == bufnr then
      return winid
    end
  end
  return nil
end

---Show `lines` in the response split, opening it (to the right, per
---`opts.split`) if it is not already visible. The caller's own window stays
---focused — sending a request should not steal the cursor away from the
---request buffer being edited.
---@param lines string[]
---@param opts { split: string }
function M.show(lines, opts)
  local bufnr = ensure_buffer()
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false

  local origin = vim.api.nvim_get_current_win()
  local winid = find_window(bufnr)
  if not winid then
    vim.cmd(opts.split or "vsplit")
    winid = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(winid, bufnr)
  end
  vim.api.nvim_set_current_win(origin)
end

return M
