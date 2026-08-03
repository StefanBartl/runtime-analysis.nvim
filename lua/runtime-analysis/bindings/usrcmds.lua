---@module 'runtime-analysis.bindings.usrcmds'
--- Registers `:RA <subcommand>` (`request`/`send`/`yank`/`cancel`, via
--- `lib.nvim.usercmd.composer`, the same verb-first shape `:DocMap`,
--- `:MDView` and `:Replace` already use) plus two flat convenience aliases,
--- `:RARequest` and `:RASend`, for this plugin's two most-used actions.
--- Split out of `init.lua` into its own `bindings/` module to match the
--- `bindings/{keymaps,usrcmds,autocmds}.lua` shape every sibling plugin
--- uses. `:RATelemetry` is not registered here: it stays a second, separate
--- compound command on its own terms (see `telemetry/command.lua`'s doc
--- comment) — the same split documentation.nvim draws between `:DocMap`
--- (writes/verifies) and `:DocBrowse` (only reads), here drawn between
--- "runs a request" and "reports on what already ran".
---
--- **Why both `:RA request`/`:RA send` and `:RARequest`/`:RASend` exist.**
--- `NEW_PROJECT.md`'s own checklist prefers one compound verb per plugin, and
--- `:RA` is that verb. But `:RARequest`/`:RASend` are this plugin's oldest,
--- most-referenced public surface — documentation.nvim's `:DocBrowse`
--- Endpoints mode already opens a request buffer via `open_request()`
--- directly (not through either command name), so no integration depends on
--- the *names* staying flat, but a user's own keymap to either flat command
--- would break silently on a bare rename. Keeping both costs four lines and
--- breaks nothing; dropping the flat pair would be a breaking change for a
--- purely cosmetic gain. `:RA yank`/`:RA cancel` get no flat alias: both are
--- new, have no external references, and no keymap could already exist for
--- either.
---
--- **`:RA send`/`:RASend` are non-blocking** (docs/ROADMAP.md §1.1) — see
--- `runner.run_async`'s own doc-comment for why every callback through it is
--- guaranteed to run outside Neovim's fast-event context, and see the
--- pending-request tracking below for what "cancel" actually means here: a
--- *logical* discard of whatever `curl` eventually returns, not a process
--- kill — `lib.nvim.net.curl.fetch_raw` does not hand back a `vim.SystemObj`
--- to kill, and extending it to do so is real, separate work in a different
--- repository, not attempted here.
---
--- No `keymaps.lua` or `autocmds.lua` sit beside this file: this plugin sets
--- zero default keymaps and zero autocmds, by design — every entry point is a
--- command, the same "no global keymaps at all" choice documentation.nvim's
--- own `:DocBrowse` keymap sheet documents for the identical reason (a request
--- buffer's own edits are what drive this plugin, not a keybinding). An empty
--- placeholder file for either would be scaffolding with nothing to scaffold.

local composer = require("lib.nvim.usercmd.composer")

local M = {}

-- Pending-request tracking (docs/ROADMAP.md §1.1). One token per send;
-- firing a new `:RA send` bumps it, which makes an earlier in-flight
-- request's own callback a silent no-op when it eventually arrives — a
-- *logical* supersession, not a queue and not a "one at a time" refusal.
-- `:RA cancel` works the same way: see `runner.run_async`'s own doc-comment
-- for why this can only ever discard the eventual result, not stop the
-- `curl` process actually producing it.
local pending_token = 0
local in_flight = false
---@type Lib.Progress.Handle?
local pending_handle = nil

---@param my_token integer
---@return boolean
local function is_current(my_token)
  return in_flight and my_token == pending_token
end

---@param ra RA
local function cancel_pending(ra)
  if not in_flight then
    vim.notify("runtime-analysis: no request in flight", vim.log.levels.WARN)
    return
  end
  if pending_handle then
    -- Runs the `on_cancel` callback registered below (which flips
    -- `in_flight` to false) before rendering the handle's own "cancelled"
    -- state — the single path both this command and any future
    -- interactive progress style's own cancel gesture would go through.
    pending_handle:request_cancel()
  else
    in_flight = false
  end
  require("runtime-analysis.view").show({ "✗ cancelled" }, { split = ra.opts.split })
end

---Parse the current buffer as a request and send it asynchronously,
---showing the response in the split `view.lua` manages once it arrives.
---
---`###`-aware (docs/ROADMAP.md §1.2): the buffer is always split into
---blocks first, and the block the cursor is in (or nearest above it) is
---the one parsed and sent — never the whole buffer verbatim, never a
---picker. A buffer with no `###` line at all splits into exactly one
---block covering everything, so this behaves exactly as it did before
---`###` support existed.
---
---Non-blocking (docs/ROADMAP.md §1.1): the editor stays responsive while
---curl runs. The response pane shows a "sending" placeholder immediately,
---then either the real response or an error/cancelled message — never
---silence while nothing visibly happens.
---@param ra RA
local function send_current_buffer(ra)
  local parse = require("runtime-analysis.parse")
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local blocks = parse.split(lines)
  local block_lines = lines
  if #blocks > 0 then
    local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
    local block = parse.block_at(blocks, cursor_line)
    block_lines = block and block.lines or lines
  end

  local request, err = parse.parse(block_lines)
  if not request then
    vim.notify("runtime-analysis: " .. err, vim.log.levels.ERROR)
    return
  end

  pending_token = pending_token + 1
  local my_token = pending_token
  in_flight = true

  local view = require("runtime-analysis.view")
  local summary = ("%s %s"):format(request.method, request.url)
  view.show({ ("→ sending %s ..."):format(summary) }, { split = ra.opts.split })

  -- Soft dependency, `pcall`-guarded like every other optional lib.nvim
  -- piece this plugin touches: async sending still works with no visible
  -- spinner if `lib.nvim.progress` is ever unavailable, it just loses the
  -- "sending..." notification and the ability to cancel *through the
  -- handle* — `cancel_pending`'s `else` branch still lets `:RA cancel`
  -- discard the result directly in that case.
  local ok_progress, progress = pcall(require, "lib.nvim.progress")
  local handle
  if ok_progress then
    handle = progress.create({ title = "[runtime-analysis]" })
    handle:update({ text = "sending " .. summary })
    handle:on_cancel(function()
      if my_token == pending_token then
        in_flight = false
      end
    end)
  end
  pending_handle = handle

  require("runtime-analysis.runner").run_async(request, function(resp_lines, run_err, meta)
    if not is_current(my_token) then
      -- Superseded by a later send, or cancelled — the result arrived,
      -- but nothing here still cares about it.
      return
    end
    in_flight = false
    if pending_handle == handle then
      pending_handle = nil
    end

    if not resp_lines then
      if handle then
        handle:cancel("failed")
      end
      vim.notify("runtime-analysis: " .. run_err, vim.log.levels.ERROR)
      view.show({ ("✗ %s"):format(run_err) }, { split = ra.opts.split })
      return
    end

    if handle then
      handle:finish("done")
    end
    view.show(resp_lines, {
      split = ra.opts.split,
      body_start = meta and meta.body_start,
      is_json = meta and meta.is_json,
    })
  end)
end

---@param ra RA The plugin's own module table — read for `ra.opts` and called
---back into for `ra.open_request` so every command stays in sync with a
---`setup()` that has already run.
function M.setup(ra)
  composer.verb("RA", {
    desc = "runtime-analysis.nvim: the HTTP request runner",
    routes = {
      {
        path = { "request" },
        desc = "Open a new HTTP request buffer",
        run = function()
          ra.open_request()
        end,
      },
      {
        path = { "send" },
        desc = "Send the current buffer as an HTTP request",
        run = function()
          send_current_buffer(ra)
        end,
      },
      {
        path = { "yank" },
        desc = "Yank just the last response's body to the unnamed register",
        run = function()
          require("runtime-analysis.view").yank_body()
        end,
      },
      {
        path = { "cancel" },
        desc = "Cancel the in-flight request, if any",
        run = function()
          cancel_pending(ra)
        end,
      },
    },
  })

  -- Flat aliases — see the module doc-comment for why these stay alongside
  -- the `:RA` verb above rather than being replaced by it.
  vim.api.nvim_create_user_command("RARequest", function()
    ra.open_request()
  end, {
    desc = "Open a new HTTP request buffer (alias: :RA request)",
  })
  vim.api.nvim_create_user_command("RASend", function()
    send_current_buffer(ra)
  end, {
    desc = "Send the current buffer as an HTTP request (alias: :RA send)",
  })
end

return M
