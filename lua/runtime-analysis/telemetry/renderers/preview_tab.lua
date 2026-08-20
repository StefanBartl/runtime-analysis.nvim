---@module 'runtime-analysis.telemetry.renderers.preview_tab'
--- Hands a rendered report to mdview.nvim's **in-editor** tab preview — no
--- relay, no browser, no binary.
---
--- **What this is for, stated against the two styles it sits between.** The
--- `"kit"` float is always available and is the wrong shape for a long
--- report: a float does not scroll comfortably, does not search, and does not
--- yank. The `"mdview"` style is the right shape and costs a browser tab and,
--- on a first run, a pause while mdview self-installs its relay binary from
--- GitHub Releases. This one is the tier between them — a real buffer, in its
--- own tab, with nothing downloaded and nothing outside Neovim involved.
---
--- **What mdview adds that a plain markdown buffer does not**, measured
--- against `mdview.adapter.preview_tab` rather than assumed: it opens the
--- mirror with `conceallevel = 2` and `concealcursor = "nc"`. With the
--- markdown Treesitter parser that hides the `**`, the backticks and the link
--- brackets, so a report *reads as prose* instead of as its own source. That
--- is the difference worth depending on another plugin for; the read-only
--- scratch buffer and the tab are things this file could have done itself.
---
--- **A snapshot, not a live dashboard, and the distinction is deliberate.**
--- The `"mdview"` style is live because the relay watches the file on disk
--- and telemetry rewrites that file on every flush. This one mirrors a
--- *buffer*, and nothing here re-reads the file after a later flush — so what
--- you get is the report as of the moment you opened it, exactly the promise
--- the `"kit"` float already makes. Saying so is cheaper than an autocmd that
--- would make the two styles differ in a second way nobody asked for.
---
--- **Why the adapter module rather than `:MDView preview-tab`.** The command
--- toggles the preview for whatever buffer is *current*, which makes it
--- unusable here twice over: a report style must not depend on which buffer
--- the reader happened to be in, and getting the report buffer to be current
--- means displacing what they were looking at first. `adapter.preview_tab`'s
--- `open(bufnr)` takes the buffer and opens its own tab, which is the shape
--- this needs. `mdview.lua` next door reaches for the command surface because
--- `:MDView standalone <path>` genuinely takes the argument it needs.
---
--- Soft dependency, never hard — the same discipline `mdview.lua` documents
--- and `lib.nvim.progress.styles.fidget` sets: `pcall` around every reach
--- into the other plugin, degrade to `false, err` rather than throwing, and
--- let the caller fall back to the float that is always there.

local M = {}

---Whether the in-editor preview is reachable at all.
---
---Both halves are checked, because they are two different absences: mdview
---may be installed while this particular adapter is not (an older release,
---a partial checkout). Reporting "no mdview" for the second would send a
---reader to install something they already have.
---@return boolean
---@return string|nil err Why not, when not.
function M.available()
  local ok_plugin = pcall(require, "mdview")
  if not ok_plugin then
    return false, "mdview.nvim is not installed/loadable"
  end
  local ok_adapter = pcall(require, "mdview.adapter.preview_tab")
  if not ok_adapter then
    return false, "this mdview.nvim has no preview-tab adapter"
  end
  return true
end

---Put `lines` in a scratch buffer and open mdview's preview tab over it.
---
---A scratch buffer rather than the report file on disk: this style writes
---nothing, which is the whole difference from `"file"`. `"file"` is for
---keeping a report; this is for reading one.
---
---The source buffer is created but never shown. It exists because the
---adapter mirrors a buffer and syncs from it — and leaving it undisplayed is
---what keeps this to *one* new tab rather than two.
---@param lines string[]
---@param title string Shown as the buffer's name, so `:ls` and the tab line say which namespace this is.
---@return boolean ok
---@return string|nil err
function M.open(lines, title)
  local ok_available, why = M.available()
  if not ok_available then
    return false, why
  end

  local source = vim.api.nvim_create_buf(false, true)
  if source == 0 then
    return false, "could not create a buffer for the report"
  end

  vim.api.nvim_buf_set_lines(source, 0, -1, false, lines)
  vim.bo[source].buftype = "nofile"
  vim.bo[source].swapfile = false
  vim.bo[source].modifiable = false
  -- Set last: the adapter refuses any buffer whose filetype is not
  -- `markdown`/`md`, and setting it before the lines are in would fire
  -- markdown's own FileType autocmds against an empty buffer.
  vim.bo[source].filetype = "markdown"
  -- Named, not anonymous, because the preview tab takes its own name from
  -- this one's basename — an unnamed source becomes `[no name]` in the tab
  -- line, which is the one place the namespace needed to be visible.
  pcall(vim.api.nvim_buf_set_name, source, title .. ".md")

  local ok_open, opened = pcall(function()
    return require("mdview.adapter.preview_tab").open(source)
  end)
  if not ok_open then
    pcall(vim.api.nvim_buf_delete, source, { force = true })
    return false, "mdview preview-tab failed: " .. tostring(opened)
  end
  if opened == false then
    -- The adapter declined rather than errored — it notifies its own reason
    -- and returns false. Cleaned up and reported, so the caller falls back
    -- instead of leaving an invisible buffer behind.
    pcall(vim.api.nvim_buf_delete, source, { force = true })
    return false, "mdview declined to preview the report buffer"
  end

  return true
end

return M
