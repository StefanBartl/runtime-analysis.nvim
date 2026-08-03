---@module 'runtime-analysis.bindings.usrcmds'
--- Registers `:RA <subcommand>` (`request`/`send`/`yank`, via
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
--- purely cosmetic gain. `:RA yank` gets no flat alias: it is new, has no
--- external references and no keymap could already exist for it.
---
--- No `keymaps.lua` or `autocmds.lua` sit beside this file: this plugin sets
--- zero default keymaps and zero autocmds, by design — every entry point is a
--- command, the same "no global keymaps at all" choice documentation.nvim's
--- own `:DocBrowse` keymap sheet documents for the identical reason (a request
--- buffer's own edits are what drive this plugin, not a keybinding). An empty
--- placeholder file for either would be scaffolding with nothing to scaffold.

local composer = require("lib.nvim.usercmd.composer")

local M = {}

---Parse the current buffer as a request and send it, showing the response
---in the split `view.lua` manages.
---
---`###`-aware (docs/ROADMAP.md §1.2): the buffer is always split into
---blocks first, and the block the cursor is in (or nearest above it) is
---the one parsed and sent — never the whole buffer verbatim, never a
---picker. A buffer with no `###` line at all splits into exactly one
---block covering everything, so this behaves exactly as it did before
---`###` support existed.
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

  local resp_lines, run_err, meta = require("runtime-analysis.runner").run(request)
  if not resp_lines then
    vim.notify("runtime-analysis: " .. run_err, vim.log.levels.ERROR)
    return
  end

  require("runtime-analysis.view").show(resp_lines, {
    split = ra.opts.split,
    body_start = meta and meta.body_start,
    is_json = meta and meta.is_json,
  })
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
