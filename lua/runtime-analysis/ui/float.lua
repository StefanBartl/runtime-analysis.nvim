---@module 'runtime-analysis.ui.float'
--- The read-only result float this plugin's reporting commands open, with the
--- winbar key legend and the `?` cheatsheet that go with it.
---
--- **Extracted from `telemetry/command.lua`, where it was a local**, the
--- moment a second command family (`:RA startup profile`) needed the same
--- float. Copying it would have meant two winbar legends, two cheatsheets and
--- two sets of keymaps drifting apart — and the legend's whole point is that
--- it is built from the very entries that were wired up, which only holds
--- while there is one place building both.
---
--- Nothing here is telemetry-specific any more: a row's key is read off the
--- current line by a function the caller supplies (`row_key_at`), and the
--- keymap descriptions carry the caller's own `desc_prefix`. What stayed
--- behind in `telemetry/command.lua` is exactly the telemetry-shaped part —
--- that a report block's header row is `"<ns>  —  <state>"`.
---
--- Built on `ui.kit.viewer` and degrading to a notification without it: a
--- headless session or a stripped runtimepath still has to be able to read
--- the data, and a report that fails to open is worse than one that arrives
--- in the message area.

local M = {}

---@internal
---The one-line key legend a float carries in its `winbar`, built from the
---very keymaps that call actually wired up — so it can never advertise a key
---this particular view does not have. Same idea (and same `key label  │  key
---label` shape) as reposcope.nvim's own status winbar: a float with five
---bindings and nothing on screen saying so is a float whose bindings nobody
---finds. `? Keys` is last and always present, since it is how everything not
---worth a legend entry stays reachable.
---@param entries { lhs: string, legend?: string }[]
---@return string
local function legend(entries)
  local parts = {}
  for _, e in ipairs(entries) do
    if e.legend then
      parts[#parts + 1] = ("%%#Special#%s %%#Comment#%s"):format(e.lhs, e.legend)
    end
  end
  parts[#parts + 1] = "%#Special#? %#Comment#Keys"
  return " " .. table.concat(parts, "%#NonText#  │  ") .. "%#Normal#"
end

---Read-only cheatsheet for a float — only lists the actions this particular
---call actually wired up.
---@param title string
---@param rows { lhs: string, desc: string }[]
---@return nil
function M.help(title, rows)
  local widest = #"?"
  for _, r in ipairs(rows) do
    widest = math.max(widest, #r.lhs)
  end
  local lines = { "", (" %s keys"):format(title), "" }
  local function row(lhs, desc)
    lines[#lines + 1] = ("  %-" .. widest .. "s   %s"):format(lhs, desc)
  end
  for _, r in ipairs(rows) do
    row(r.lhs, r.desc)
  end
  row("?", "Show this help")
  lines[#lines + 1] = ""
  local width = 40
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  require("ui.kit").viewer({
    lines = lines,
    title = title .. " Keys",
    filetype = "runtime-analysis-help",
    width = math.min(width + 2, math.floor(vim.o.columns * 0.9)),
    height = math.min(#lines, math.floor(vim.o.lines * 0.8)),
  })
end

---@class RA.UI.Float.Key
---@field lhs string
---@field desc string Shown in the `?` cheatsheet.
---@field legend? string Shown in the winbar. Omitted keys still work; they are just not advertised there.
---@field run fun(bufnr: integer, set_lines: fun(lines: string[]), set_title: fun(title: string)): nil

---@class RA.UI.Float.Opts
---@field on_refresh? fun(): string[]|nil Recompute and return fresh lines for the same view.
---@field on_drilldown? fun(key: string): string[]|nil, string|nil Offered the row key under the cursor on `<CR>`; returning `lines[, title]` swaps this same float to that view in place, returning nothing leaves the float as is.
---@field row_key_at? fun(line: string): string|nil How the key under the cursor is read off a line. Required for `on_drilldown` to do anything.
---@field on_open_html? fun(): nil Write and open this same report's HTML rendering in the system browser (`gO`).
---@field on_lines? fun(bufnr: integer, lines: string[]): nil Runs after every set of lines is installed (the initial ones and every refresh), for a view that highlights its own heading/summary rows.
---@field table_view? boolean Turns off wrapping and turns on `cursorline`: a wrapped row in an aligned table destroys the alignment that is the whole point of it, and a row-addressed view needs to show which row is current.
---@field keys? RA.UI.Float.Key[] Extra bindings, wired after the built-in ones and listed in the same legend and cheatsheet.
---@field desc_prefix? string Prefix for the keymap descriptions and the fallback notification. Default `"runtime-analysis"`.

---Show `lines` in a read-only float titled `title`.
---@param lines string[]
---@param title string
---@param opts? RA.UI.Float.Opts
---@return nil
function M.show(lines, title, opts)
  opts = opts or {}
  local prefix = opts.desc_prefix or "runtime-analysis"

  local ok, kit = pcall(require, "ui.kit")
  if not ok then
    -- No kit (a stripped runtimepath, a headless session): the data still
    -- has to be reachable, so fall back to the message area rather than
    -- failing.
    require("lib.nvim.notify").create("[" .. prefix .. "]").info(table.concat(lines, "\n"))
    return
  end

  -- Built before the float opens, because the winbar legend is derived from
  -- this same list and has to be set at open time.
  local entries = {}
  if opts.on_refresh then
    entries[#entries + 1] = { lhs = "r", desc = "Refresh", legend = "Refresh" }
  end
  if opts.on_drilldown then
    entries[#entries + 1] =
      { lhs = "<CR>", desc = "Open the row under the cursor", legend = "Open" }
  end
  if opts.on_open_html then
    entries[#entries + 1] =
      { lhs = "gO", desc = "Open this report as HTML in the browser", legend = "HTML" }
  end
  for _, k in ipairs(opts.keys or {}) do
    entries[#entries + 1] = { lhs = k.lhs, desc = k.desc, legend = k.legend }
  end

  local surf = kit.viewer({
    lines = lines,
    title = (" %s "):format(title),
    width = math.min(110, math.max(60, vim.o.columns - 8)),
    -- +1 for the winbar, which otherwise eats a row of content out of a
    -- height sized to the line count (kit clamps it to the editor anyway).
    height = math.min(#lines + 1, math.max(1, vim.o.lines - 6)),
  })
  if not surf then
    return
  end

  if vim.api.nvim_win_is_valid(surf.winid) then
    vim.api.nvim_set_option_value("winbar", legend(entries), { win = surf.winid })
    if opts.table_view then
      vim.api.nvim_set_option_value("wrap", false, { win = surf.winid })
      vim.api.nvim_set_option_value("cursorline", true, { win = surf.winid })
      -- Line 1 is the heading row; start on the first row that is actually
      -- content, so `<CR>` works without moving first.
      pcall(vim.api.nvim_win_set_cursor, surf.winid, { math.min(2, #lines), 0 })
    end
  end
  if opts.on_lines then
    opts.on_lines(surf.bufnr, lines)
  end

  local help_rows = { { lhs = "j/k", desc = "Move" } }
  for _, e in ipairs(entries) do
    help_rows[#help_rows + 1] = { lhs = e.lhs, desc = e.desc }
  end
  help_rows[#help_rows + 1] = { lhs = "q, <Esc>", desc = "Close" }

  local km = { noremap = true, silent = true, buffer = surf.bufnr }
  local keymap = require("lib.nvim.bindings.keymap")

  ---Install a fresh set of lines, keeping whatever `on_lines` decoration the
  ---view applies to them — a refresh that dropped the highlights would leave
  ---the heading row looking like an ordinary row from then on.
  ---@param fresh string[]
  local function set_lines(fresh)
    surf:set_lines(fresh)
    if opts.on_lines then
      opts.on_lines(surf.bufnr, fresh)
    end
  end

  ---@param new_title string
  local function set_title(new_title)
    surf:set_title((" %s "):format(new_title))
  end

  if opts.on_refresh then
    keymap("n", "r", function()
      local fresh = opts.on_refresh()
      if fresh then
        set_lines(fresh)
      end
    end, km, prefix .. ": refresh")
  end
  if opts.on_drilldown then
    keymap("n", "<CR>", function()
      local key = opts.row_key_at and opts.row_key_at(vim.api.nvim_get_current_line())
      if not key then
        return
      end
      local new_lines, new_title = opts.on_drilldown(key)
      if new_lines then
        set_lines(new_lines)
        if new_title then
          set_title(new_title)
        end
      end
    end, km, prefix .. ": drill into the row under the cursor")
  end
  if opts.on_open_html then
    keymap("n", "gO", opts.on_open_html, km, prefix .. ": open as HTML")
  end
  for _, k in ipairs(opts.keys or {}) do
    keymap("n", k.lhs, function()
      k.run(surf.bufnr, set_lines, set_title)
    end, km, prefix .. ": " .. k.desc)
  end

  keymap("n", "?", function()
    M.help(title, help_rows)
  end, km, prefix .. ": show keymap cheatsheet")
end

return M
