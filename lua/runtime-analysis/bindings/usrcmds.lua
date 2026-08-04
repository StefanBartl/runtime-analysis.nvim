---@module 'runtime-analysis.bindings.usrcmds'
--- Registers `:RA <subcommand>` (`request`/`send`/`yank`/`cancel`/
--- `history`/`history clear`, via `lib.nvim.usercmd.composer`, the same
--- verb-first shape `:DocMap`, `:MDView` and `:Replace` already use) plus
--- two flat convenience aliases, `:RARequest` and `:RASend`, for this
--- plugin's two most-used actions. Split out of `init.lua` into its own
--- `bindings/` module to match the `bindings/{keymaps,usrcmds,autocmds}.lua`
--- shape every sibling plugin uses. `:RATelemetry` is not registered here:
--- it stays a second, separate compound command on its own terms (see
--- `telemetry/command.lua`'s doc comment) — the same split
--- documentation.nvim draws between `:DocMap` (writes/verifies) and
--- `:DocBrowse` (only reads), here drawn between "runs a request" and
--- "reports on what already ran".
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
--- purely cosmetic gain. `:RA yank`/`:RA cancel`/`:RA history` get no flat
--- alias: all are new, have no external references, and no keymap could
--- already exist for any of them.
---
--- **`:RA history`** (docs/ROADMAP.md §1.3) reads `runtime-analysis.history`,
--- a per-project record of method/url/status/timestamp for every send this
--- module makes — see that module's own doc-comment for exactly what is
--- and is not recorded, and why. Every outcome records: a real response, a
--- transport failure, a cancellation, and even a *superseded* send's real
--- eventual result once it is known — the one thing that is never recorded
--- twice for the same send.
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

-- A dynamic completer, registered once: `M.setup` may run more than once in
-- a session (`:source`-ing config during development), and
-- `composer.register_type` overwriting an existing name is exactly what
-- that needs — registering here, at require-time, means `:RA env <Tab>`
-- always reflects whatever `runtime-analysis.env`'s files say *right now*,
-- not a list frozen when `setup()` first ran.
composer.register_type("RA_ENV_NAME", {
  validate = function(raw)
    return true, raw, nil
  end,
  complete = function(arg_lead)
    local names = require("runtime-analysis.env").list_names()
    return vim.tbl_filter(function(n)
      return n:find(arg_lead or "", 1, true) == 1
    end, names)
  end,
})

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
---The method/url of the currently in-flight request — tracked as module
---state (not just a `send_current_buffer` local) purely so `cancel_pending`
---can record a history entry for it; `send_current_buffer`'s own success/
---error path already has `request` in scope via closure and does not read
---this.
---@type { method: string, url: string }?
local pending_request = nil

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
  if pending_request then
    require("runtime-analysis.history").record(
      pending_request.method,
      pending_request.url,
      nil,
      "cancelled"
    )
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

  -- docs/ROADMAP.md §2.1: `{{name}}` placeholders resolve against the
  -- selected environment right here, immediately before the request goes
  -- out — `request` itself stays untouched below (the "sending" summary,
  -- the pending-request record, and the history entry all read `request`,
  -- never `resolved_request`), so a `{{token}}` renders as `{{token}}`
  -- everywhere except inside the one real outgoing request.
  local resolved_request, resolve_err = require("runtime-analysis.env").resolve(request)
  if not resolved_request then
    vim.notify("runtime-analysis: " .. resolve_err, vim.log.levels.ERROR)
    return
  end

  pending_token = pending_token + 1
  local my_token = pending_token
  in_flight = true
  pending_request = { method = request.method, url = request.url }

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

  require("runtime-analysis.runner").run_async(resolved_request, function(resp_lines, run_err, meta)
    if not is_current(my_token) then
      -- Two different reasons land here, and only one still needs a
      -- history entry: a cancelled request (`pending_token == my_token`,
      -- `in_flight` already false) was already recorded with note
      -- "cancelled" at cancel time — recording it again here with its real,
      -- now-irrelevant outcome would just double it up. A *superseded*
      -- request (`pending_token ~= my_token`, some later send moved it on)
      -- was never recorded at all yet, and its real outcome is worth
      -- keeping even though nothing renders it — the request genuinely
      -- happened.
      if pending_token ~= my_token then
        require("runtime-analysis.history").record(
          request.method,
          request.url,
          meta and meta.status,
          (not resp_lines) and run_err or nil
        )
      end
      return
    end
    in_flight = false
    pending_request = nil
    if pending_handle == handle then
      pending_handle = nil
    end

    require("runtime-analysis.history").record(
      request.method,
      request.url,
      meta and meta.status,
      (not resp_lines) and run_err or nil
    )

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

---`vim.ui.select` rather than the quickfix list documentation.nvim's own
---commands favor — this is "pick exactly one thing and act on it", not
---"here are several locations to jump through", so the native
---pick-one primitive is the right one, and it defers to whatever picker UI
---(telescope, fzf-lua, snacks, or Neovim's own default) the reader already
---has configured rather than this plugin inventing its own.
---@param ra RA
local function browse_history(ra)
  local history = require("runtime-analysis.history")
  local entries = history.list()
  if #entries == 0 then
    vim.notify("runtime-analysis: no request history for this project yet", vim.log.levels.INFO)
    return
  end

  vim.ui.select(entries, {
    prompt = "runtime-analysis: request history (newest first)",
    ---@param e RA.History.Entry
    format_item = function(e)
      local outcome = e.status and tostring(e.status) or (e.note or "?")
      return ("%s  %-10s %-6s %s"):format(os.date("%Y-%m-%d %H:%M", e.at), outcome, e.method, e.url)
    end,
  }, function(choice)
    if not choice then
      return
    end
    -- Reopens exactly the way documentation.nvim's own Endpoints mode
    -- already does — method and path pre-filled, nothing else assumed —
    -- since this history entry is, by design, exactly that much and no
    -- more (see history.lua's own doc-comment for why headers and body
    -- were never recorded to begin with).
    ra.open_request({ ("%s %s"):format(choice.method, choice.url), "" })
  end)
end

---`:RA env [name]` (docs/ROADMAP.md §2.1). With `name`, selects it directly
---(or reports the available names if it doesn't exist); with no argument,
---offers every name the project's env files define via `vim.ui.select`, the
---same picker `browse_history` above already uses for the identical "pick
---exactly one thing" shape.
---@param name string?
local function select_environment(name)
  local env = require("runtime-analysis.env")

  if name and name ~= "" then
    local ok, err = env.set_current(name)
    if ok then
      vim.notify("runtime-analysis: environment set to " .. name)
    else
      vim.notify("runtime-analysis: " .. err, vim.log.levels.ERROR)
    end
    return
  end

  local names = env.list_names()
  if #names == 0 then
    vim.notify(
      "runtime-analysis: no environments defined — create "
        .. env.SHARED_FILE
        .. " at the project root",
      vim.log.levels.INFO
    )
    return
  end

  vim.ui.select(names, {
    prompt = ("runtime-analysis: select environment (current: %s)"):format(
      env.current() or "none"
    ),
  }, function(choice)
    if not choice then
      return
    end
    local ok, err = env.set_current(choice)
    if ok then
      vim.notify("runtime-analysis: environment set to " .. choice)
    else
      vim.notify("runtime-analysis: " .. err, vim.log.levels.ERROR)
    end
  end)
end

---`:RA import` (docs/ROADMAP.md §2.3) — parses a `curl` command line into a
---new request buffer via `ra.open_request`, the same entry point
---documentation.nvim's own Endpoints mode already uses. Two sources, in
---order of precedence: a real visual/line-range invocation (`'<,'>RA
---import`) reads the selected lines; a bare `:RA import` reads the system
---clipboard (`+`), falling back to the unnamed register — "paste a curl
---command" is the roadmap entry's own framing, and a real OS paste is
---exactly what that means for a bare invocation with nothing selected.
---@param ra RA
---@param ctx table composer's handler context — only `ctx.range` is read
local function do_import(ra, ctx)
  local source
  if ctx.range and ctx.range.range and ctx.range.range > 0 then
    local lines = vim.api.nvim_buf_get_lines(0, ctx.range.line1 - 1, ctx.range.line2, false)
    source = table.concat(lines, "\n")
  else
    local clipboard = vim.fn.getreg("+")
    source = (clipboard ~= "" and clipboard) or vim.fn.getreg('"')
  end

  if not source or vim.trim(source) == "" then
    vim.notify(
      "runtime-analysis: nothing to import — select a curl command, or copy one to the clipboard first",
      vim.log.levels.WARN
    )
    return
  end

  local request, err = require("runtime-analysis.curl").parse(source)
  if not request then
    vim.notify("runtime-analysis: " .. err, vim.log.levels.ERROR)
    return
  end

  local lines = { ("%s %s"):format(request.method, request.url) }
  local names = vim.tbl_keys(request.headers)
  table.sort(names)
  for _, name in ipairs(names) do
    lines[#lines + 1] = ("%s: %s"):format(name, request.headers[name])
  end
  if request.body then
    lines[#lines + 1] = ""
    vim.list_extend(lines, vim.split(request.body, "\n", { plain = true }))
  end

  ra.open_request(lines)
end

---`:RA export` (docs/ROADMAP.md §2.3) — the reverse of `:RA import`: parses
---whichever `###` block the cursor is in (the identical resolution `:RA
---send` uses) and formats it as a `curl` command line via
---`runtime-analysis.curl.format`, yanked to the unnamed register the same
---way `:RA yank` already yanks a response body.
---
---**Never resolves `{{var}}` placeholders** — `runtime-analysis.curl.format`
---is handed the raw, unresolved request `parse.parse` returns, the same
---request `send_current_buffer` keeps for history/the "sending ..."
---placeholder. Exporting is sharing, and `runtime-analysis.env`'s own trap
---applies here identically: a `{{token}}` must render as `{{token}}`,
---never the value it would resolve to.
local function do_export()
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

  local cmd = require("runtime-analysis.curl").format(request)
  vim.fn.setreg('"', cmd)
  vim.notify("runtime-analysis: curl command yanked to the unnamed register")
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
      {
        path = { "history" },
        desc = "Browse this project's request history and reopen one",
        run = function()
          browse_history(ra)
        end,
      },
      {
        path = { "history", "clear" },
        desc = "Clear this project's request history",
        run = function()
          require("runtime-analysis.history").clear()
          vim.notify("runtime-analysis: request history cleared")
        end,
      },
      {
        path = { "env" },
        desc = "Show/select the environment {{vars}} resolve against",
        args = { { name = "name", type = "RA_ENV_NAME", optional = true } },
        run = function(ctx)
          select_environment(ctx.args.name)
        end,
      },
      {
        path = { "import" },
        desc = "Import a curl command (visual selection, or the clipboard) into a new request buffer",
        range = true,
        run = function(ctx)
          do_import(ra, ctx)
        end,
      },
      {
        path = { "export" },
        desc = "Export the request under the cursor as a curl command, yanked to the unnamed register",
        run = function()
          do_export()
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
