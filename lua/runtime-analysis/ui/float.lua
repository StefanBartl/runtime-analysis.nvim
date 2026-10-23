---@module 'runtime-analysis.ui.float'
--- The read-only result float this plugin's reporting commands open: this
--- plugin's defaults on top of `ui.kit.viewer`.
---
--- The float itself (winbar key legend, `?` cheatsheet, keymaps derived from
--- one list, `table_view`, the decoration hook that survives a refresh) is a
--- `ui.kit.viewer` feature (`keys`, `table_view`, `on_lines`, see
--- `ui.nvim`'s `lua/ui/kit/viewer_keys.lua`). It used to live here, and was
--- moved out when `hover.nvim` needed the same shape a third time. What is
--- left is what is specific to `:RA`: that a refresh, a drill-down into the
--- row under the cursor and an HTML export are the built-in keys, the
--- keymap description prefix, and the fallback when there is no kit.
---
--- Degrades to a notification without `ui.nvim`, and also with a `ui.nvim`
--- that predates `viewer` keys: a headless session or a stripped runtimepath
--- still has to be able to read the data, and a float without the keys it
--- would advertise is worse than the same report in the message area.

local M = {}

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

---The `ui.kit.viewer` keys for this call: the built-in ones this call has the
---handlers for, then the caller's own.
---@param opts RA.UI.Float.Opts
---@return Ui.Kit.ViewerKey[]
local function viewer_keys(opts)
  ---@type Ui.Kit.ViewerKey[]
  local keys = {}
  if opts.on_refresh then
    keys[#keys + 1] = {
      lhs = "r",
      desc = "Refresh",
      legend = "Refresh",
      run = function(view)
        local fresh = opts.on_refresh()
        if fresh then
          view.set_lines(fresh)
        end
      end,
    }
  end
  if opts.on_drilldown then
    keys[#keys + 1] = {
      lhs = "<CR>",
      desc = "Open the row under the cursor",
      legend = "Open",
      run = function(view)
        local key = opts.row_key_at and opts.row_key_at(vim.api.nvim_get_current_line())
        if not key then
          return
        end
        local new_lines, new_title = opts.on_drilldown(key)
        if new_lines then
          view.set_lines(new_lines)
          if new_title then
            view.set_title((" %s "):format(new_title))
          end
        end
      end,
    }
  end
  if opts.on_open_html then
    keys[#keys + 1] = {
      lhs = "gO",
      desc = "Open this report as HTML in the browser",
      legend = "HTML",
      run = function()
        opts.on_open_html()
      end,
    }
  end
  for _, k in ipairs(opts.keys or {}) do
    keys[#keys + 1] = {
      lhs = k.lhs,
      desc = k.desc,
      legend = k.legend,
      run = function(view)
        k.run(view.bufnr, view.set_lines, function(title)
          view.set_title((" %s "):format(title))
        end)
      end,
    }
  end
  return keys
end

---Show `lines` in a read-only float titled `title`.
---@param lines string[]
---@param title string
---@param opts? RA.UI.Float.Opts
---@return nil
function M.show(lines, title, opts)
  opts = opts or {}
  local prefix = opts.desc_prefix or "runtime-analysis"

  local ok, kit = pcall(require, "ui.kit")
  if not ok or not pcall(require, "ui.kit.viewer_keys") then
    -- No kit, or one without viewer keys: the data still has to be reachable,
    -- so fall back to the message area rather than failing.
    require("lib.nvim.notify").create("[" .. prefix .. "]").info(table.concat(lines, "\n"))
    return
  end

  kit.viewer({
    lines = lines,
    title = (" %s "):format(title),
    width = math.min(110, math.max(60, vim.o.columns - 8)),
    keys = viewer_keys(opts),
    desc_prefix = prefix,
    help_title = title,
    help_filetype = "runtime-analysis-help",
    table_view = opts.table_view,
    on_lines = opts.on_lines,
  })
end

return M
