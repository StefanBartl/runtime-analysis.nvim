---@module 'runtime-analysis.bindings.usrcmds'
--- Registers `:RA <subcommand>` (via `lib.nvim.usercmd.composer`, the same
--- verb-first shape `:DocMap`, `:MDView` and `:Replace` already use) plus two
--- flat convenience aliases, `:RARequest` and `:RASend`, for this plugin's
--- two most-used actions. Split out of `init.lua` into its own `bindings/`
--- module to match the `bindings/{keymaps,usrcmds,autocmds}.lua` shape every
--- sibling plugin uses. `:RATelemetry` is not registered here: it stays a
--- second, separate compound command on its own terms (see
--- `telemetry/command.lua`'s doc comment) — the same split documentation.nvim
--- draws between `:DocMap` (writes/verifies) and `:DocBrowse` (only reads),
--- here drawn between "runs a request" and "reports on what already ran".
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
--- purely cosmetic gain.
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
---@param ra RA
local function send_current_buffer(ra)
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

  require("runtime-analysis.view").show(resp_lines, { split = ra.opts.split })
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
