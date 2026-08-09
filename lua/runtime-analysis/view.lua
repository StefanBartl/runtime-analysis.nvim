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

local notify = require("lib.nvim.notify").create("[runtime-analysis]")

local M = {}

local BUFNAME = "runtime-analysis://response"

---The response buffer, creating it if it does not exist yet. Named and
---looked up by name rather than kept in a module-level variable, so a
---`:bwipeout` or a fresh `:source` of this file during development does not
---leave a stale, invalid bufnr behind — `vim.fn.bufnr` always answers
---against what Neovim itself currently has.
---@internal
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
---@internal
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
---
---`opts.body_start`/`opts.is_json` come from `runner.lua`'s own return —
---stored buffer-local (`body_start`, for `M.yank_body`) or applied directly
---(`is_json`, for filetype/folding) rather than re-parsed from `lines` here,
---so this module never has to know the status/headers/body layout
---`runner.lua` actually produces.
---@param lines string[]
---@param opts { split: string, body_start?: integer, is_json?: boolean }
function M.show(lines, opts)
  local bufnr = ensure_buffer()
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  vim.b[bufnr].runtime_analysis_body_start = opts.body_start

  -- `json` when the body is JSON (real highlighting + bracket-matching for
  -- the part of the buffer that is actually structured data), the plain
  -- custom filetype otherwise. Applies to the *whole* buffer, including the
  -- status/header preamble above the body — those lines simply do not match
  -- anything under `json` and render unhighlighted, a real but honest
  -- trade-off against splitting the preamble into a second buffer/window,
  -- which is real, separate work this plugin's simple "one persistent
  -- split" design does not currently pay for.
  vim.bo[bufnr].filetype = opts.is_json and "json" or "runtime-analysis-response"

  local origin = vim.api.nvim_get_current_win()
  local winid = find_window(bufnr)
  if not winid then
    vim.cmd(opts.split or "vsplit")
    winid = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(winid, bufnr)
  end

  -- Window-local, and reset on every call (not only when `is_json`): the
  -- window is reused across sends, so a later plain-text response must not
  -- inherit an earlier JSON response's folds. Indent-based folding is safe
  -- to apply across the whole buffer even though the preamble is not JSON —
  -- it folds purely on leading whitespace, and the unindented status/header
  -- lines simply never fold (fold level 0), so nothing there is affected.
  if opts.is_json then
    vim.wo[winid].foldmethod = "indent"
    vim.wo[winid].foldenable = true
  else
    vim.wo[winid].foldmethod = "manual"
    vim.wo[winid].foldenable = false
  end

  vim.api.nvim_set_current_win(origin)
end

---Yank the response body — the part of the buffer at or after
---`opts.body_start` from the most recent `M.show` — to the unnamed
---register, leaving headers and status out. A no-op with a clear message
---rather than an error when there is nothing to yank yet (no `:RA send`
---this session) or the last response had no body at all.
function M.yank_body()
  local bufnr = vim.fn.bufnr(BUFNAME)
  local body_start = bufnr ~= -1 and vim.b[bufnr].runtime_analysis_body_start or nil
  if not body_start then
    notify.warn("no response yet — run :RA send first")
    return
  end

  local total = vim.api.nvim_buf_line_count(bufnr)
  if body_start > total then
    notify.warn("the last response had no body")
    return
  end

  local body = vim.api.nvim_buf_get_lines(bufnr, body_start - 1, -1, false)
  vim.fn.setreg('"', table.concat(body, "\n"))
  notify.info(("yanked %d line(s) of the response body"):format(#body))
end

return M
