---@module 'runtime-analysis.ui.columns'
--- Column layout for this plugin's aligned terminal tables.
---
--- Every aligned table here pads in *display cells* rather than bytes. A
--- namespace, an argument fingerprint or a plugin path can carry multi-byte
--- characters, and `%-20s` counts bytes, so one `·` or `ü` in a cell shifts
--- that row's whole tail one column left of every other row's.
---
--- **Extracted from `telemetry/report.lua`, where these were locals**, when
--- `startup/profile.lua` grew a table of its own and got the byte-padding
--- wrong in exactly the way the comment above had already warned about. A
--- rule written down in one file's header is a rule the next file does not
--- read; a module it has to call is one it cannot get wrong.

local M = {}

--- Two spaces between every pair of columns — the same gutter reposcope.nvim's
--- own status table uses, so two overviews from the same ecosystem do not
--- disagree about what a column break looks like.
M.GAP = "  "

---Left-align `s` in `width` display cells.
---@param s string
---@param width integer
---@return string
function M.ljust(s, width)
  local pad = width - vim.fn.strdisplaywidth(s)
  return pad > 0 and (s .. (" "):rep(pad)) or s
end

---Right-align `s` in `width` display cells.
---@param s string
---@param width integer
---@return string
function M.rjust(s, width)
  local pad = width - vim.fn.strdisplaywidth(s)
  return pad > 0 and ((" "):rep(pad) .. s) or s
end

---Truncate to `width` display cells, marking the cut with an ellipsis. Cuts
---the tail: a namespace and a function key are both recognised by how they
---start.
---
---`strcharpart`, not `sub`: cutting at a byte offset can land in the middle
---of a multi-byte sequence and put an invalid byte in the buffer. But a
---*character* count is not a *display-cell* count either — a run of
---double-width characters (CJK, many emoji) packs two cells into one
---`strcharpart` unit, so `strcharpart(s, 0, width - 1)` can hand back a
---string that is still wider than `width` once the ellipsis is appended, or
---even the whole input unchanged when it has fewer characters than
---`width - 1` despite being far wider than `width` cells. Built up one
---character at a time instead, stopping as soon as the next character would
---push the running display width past the budget — the same reason
---`ljust`/`rjust` above measure with `strdisplaywidth` rather than `#s`.
---@param s string
---@param width integer
---@return string
function M.elide(s, width)
  if width <= 0 then
    return ""
  end
  if vim.fn.strdisplaywidth(s) <= width then
    return s
  end

  local ellipsis = "…"
  local ellipsis_w = vim.fn.strdisplaywidth(ellipsis)
  if width <= ellipsis_w then
    return vim.fn.strcharpart(ellipsis, 0, width)
  end

  local budget = width - ellipsis_w
  local out = ""
  local nchars = vim.fn.strcharlen(s)
  for i = 0, nchars - 1 do
    local candidate = out .. vim.fn.strcharpart(s, i, 1)
    if vim.fn.strdisplaywidth(candidate) > budget then
      break
    end
    out = candidate
  end
  return out .. ellipsis
end

---Join already-padded cells with the standard gutter, dropping trailing
---whitespace so a right-padded last column does not leave a ragged edge for
---`$`/visual selection to run into.
---@param cells string[]
---@return string
function M.join_cells(cells)
  return (table.concat(cells, M.GAP):gsub("%s+$", ""))
end

return M
