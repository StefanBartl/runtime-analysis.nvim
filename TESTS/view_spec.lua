-- TESTS/view_spec.lua — runtime-analysis.view
--
-- Real buffers and windows, not mocked — the same reason
-- documentation.nvim's own docmap_browse_spec mounts real floats: a
-- window/buffer lifecycle is exactly the kind of thing a mock would get
-- subtly wrong.

return function(H)
  local eq, ok = H.eq, H.ok

  local view = require("runtime-analysis.view")

  local origin = vim.api.nvim_get_current_win()

  -- Before any `M.show` call this session, there is no response buffer at
  -- all yet — `M.yank_body` must warn, not error, and must not create one
  -- as a side effect of being asked about it.
  do
    local warned
    local orig_notify = vim.notify
    -- A test double over typed `vim.*` surface: replacing the field is the
    -- point of the case, not a second definition of it.
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(msg, level)
      warned = { msg = msg, level = level }
    end
    view.yank_body()
    vim.notify = orig_notify
    ok(warned ~= nil, "yank_body: warns rather than erroring with no response yet")
    eq(warned.level, vim.log.levels.WARN, "yank_body: ... at WARN level")
    eq(
      vim.fn.bufnr("runtime-analysis://response"),
      -1,
      "yank_body: creates no buffer as a side effect"
    )
  end

  view.show({ "line one", "line two" }, { split = "vsplit" })

  local bufnr = vim.fn.bufnr("runtime-analysis://response")
  ok(bufnr ~= -1, "view.show: the response buffer exists after the first call")
  eq(
    table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "|"),
    "line one|line two",
    "view.show: the lines are what was passed"
  )
  eq(vim.bo[bufnr].modifiable, false, "view.show: the buffer is left non-modifiable")
  eq(
    vim.bo[bufnr].filetype,
    "runtime-analysis-response",
    "view.show: plain filetype when opts.is_json is unset"
  )
  eq(
    vim.api.nvim_get_current_win(),
    origin,
    "view.show: focus stays on the caller's window, not the new split"
  )

  local winid_after_first = nil
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(w) == bufnr then
      winid_after_first = w
    end
  end
  ok(winid_after_first ~= nil, "view.show: a window now shows the response buffer")

  -- A second call reuses the same buffer and the same window — sending a
  -- second request should update the existing pane, not stack up a new
  -- split every time.
  view.show({ "second response" }, { split = "vsplit" })
  local bufnr_again = vim.fn.bufnr("runtime-analysis://response")
  eq(bufnr_again, bufnr, "view.show: the same named buffer is reused, not recreated")

  local winid_after_second = nil
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(w) == bufnr then
      winid_after_second = w
    end
  end
  eq(
    winid_after_second,
    winid_after_first,
    "view.show: the same window is reused when the response buffer is already visible"
  )
  eq(
    table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "|"),
    "second response",
    "view.show: the buffer's content is replaced, not appended to"
  )

  -- A JSON response: filetype becomes "json", folding turns on, and
  -- `yank_body` copies exactly the body lines (not the status/headers
  -- above them) to the unnamed register.
  do
    view.show(
      { "200 OK", "content-type: application/json", "", "{", '  "a": 1', "}" },
      { split = "vsplit", body_start = 4, is_json = true }
    )
    local resp_bufnr = vim.fn.bufnr("runtime-analysis://response")
    eq(vim.bo[resp_bufnr].filetype, "json", "view.show: json filetype when opts.is_json is true")

    local winid
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(w) == resp_bufnr then
        winid = w
      end
    end
    ok(winid ~= nil, "view.show: a window shows the json response")
    eq(
      vim.wo[winid].foldmethod,
      "indent",
      "view.show: indent folding turned on for a json response"
    )
    ok(vim.wo[winid].foldenable, "view.show: folding enabled for a json response")

    view.yank_body()
    eq(
      vim.fn.getreg('"'),
      '{\n  "a": 1\n}',
      "yank_body: copies only the body lines, joined, to the unnamed register"
    )

    -- A later, non-json response reuses the same window and must not leave
    -- the earlier response's folding behind.
    view.show({ "200 OK", "", "plain text" }, { split = "vsplit", body_start = 3, is_json = false })
    eq(
      vim.wo[winid].foldmethod,
      "manual",
      "view.show: folding is reset, not inherited, when a later response is not json"
    )
    ok(not vim.wo[winid].foldenable, "view.show: ... folding disabled too")
    eq(
      vim.bo[resp_bufnr].filetype,
      "runtime-analysis-response",
      "view.show: filetype reset to plain for the non-json response"
    )

    view.yank_body()
    eq(vim.fn.getreg('"'), "plain text", "yank_body: tracks the most recent response's body_start")
    -- Not closed here: this is the same persistent window `winid_after_second`
    -- already points at (the response buffer is looked up by name throughout
    -- this spec), and the cleanup below closes it once.
  end

  -- ERR-22: an invalid opts.split value must degrade to the default split
  -- rather than break the response pane -- and the fallback must be visible
  -- via `view.bad_split_value()` for :checkhealth to report.
  do
    eq(view.bad_split_value(), nil, "bad_split_value: nil before any split has ever failed")

    -- Close the existing response window so `M.show` takes the "open a new
    -- split" branch below rather than reusing an already-visible one.
    if winid_after_second and vim.api.nvim_win_is_valid(winid_after_second) then
      vim.api.nvim_win_close(winid_after_second, true)
    end

    local warned
    local orig_notify = vim.notify
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(msg, level)
      warned = { msg = msg, level = level }
    end
    view.show({ "after a bad split value" }, { split = "totally-not-a-real-ex-command" })
    vim.notify = orig_notify

    ok(warned ~= nil, "view.show: an invalid split value still warns, doesn't raise")
    eq(
      view.bad_split_value(),
      "totally-not-a-real-ex-command",
      "bad_split_value: records the invalid value for :checkhealth"
    )

    local fallback_bufnr = vim.fn.bufnr("runtime-analysis://response")
    local fallback_winid
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(w) == fallback_bufnr then
        fallback_winid = w
      end
    end
    ok(fallback_winid ~= nil, "view.show: falls back to opening a real split (vsplit)")
    eq(
      table.concat(vim.api.nvim_buf_get_lines(fallback_bufnr, 0, -1, false), "|"),
      "after a bad split value",
      "view.show: the response is still shown despite the bad split value"
    )

    if fallback_winid and vim.api.nvim_win_is_valid(fallback_winid) then
      vim.api.nvim_win_close(fallback_winid, true)
    end
  end

  -- ERR-22 regression: a `|`-separated compound `opts.split` whose first
  -- part succeeds before a later part errors (e.g. "vsplit | badcmd") must
  -- not leak the window that first part already opened. `pcall` only
  -- reports whether the whole compound command errored, not whether a
  -- window was already created before it did, so the fallback has to clean
  -- that partial window up itself rather than just stacking its own
  -- `vsplit` on top of it.
  do
    local wins_before = #vim.api.nvim_list_wins()

    local warned
    local orig_notify = vim.notify
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(msg, level)
      warned = { msg = msg, level = level }
    end
    view.show(
      { "after a partially-successful compound split" },
      { split = "vsplit | thisIsNotARealCommand12345" }
    )
    vim.notify = orig_notify

    ok(warned ~= nil, "view.show: a partially-successful compound split still warns")
    eq(
      view.bad_split_value(),
      "vsplit | thisIsNotARealCommand12345",
      "bad_split_value: records the compound value too"
    )

    local wins_after = #vim.api.nvim_list_wins()
    eq(
      wins_after,
      wins_before + 1,
      "view.show: only the fallback's own vsplit remains -- no stray leaked window"
    )

    local fallback_bufnr = vim.fn.bufnr("runtime-analysis://response")
    local fallback_winid
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(w) == fallback_bufnr then
        fallback_winid = w
      end
    end
    ok(fallback_winid ~= nil, "view.show: the response is still shown in a real window")
    eq(
      table.concat(vim.api.nvim_buf_get_lines(fallback_bufnr, 0, -1, false), "|"),
      "after a partially-successful compound split",
      "view.show: ... with the right content"
    )

    if fallback_winid and vim.api.nvim_win_is_valid(fallback_winid) then
      vim.api.nvim_win_close(fallback_winid, true)
    end
  end

  -- The fold options set for the response window must stay window-LOCAL.
  -- `vim.wo[winid].x = v` has `:set` semantics and also rewrites the window's
  -- default ("allbuf") value, which every buffer first shown in that window
  -- inherits -- a later `:edit` in the response split would pick up the
  -- response's folding. `vim.go.*` read inside the window is that default.
  do
    local function default_folds(win)
      return vim.api.nvim_win_call(win, function()
        return vim.go.foldmethod .. "/" .. tostring(vim.go.foldenable)
      end)
    end

    -- The harness runs with the shipped defaults; make the window default
    -- something no response folding equals, so a leak cannot hide behind it.
    local saved_fm, saved_fe = vim.go.foldmethod, vim.go.foldenable
    vim.go.foldmethod, vim.go.foldenable = "expr", true
    local before = default_folds(origin)

    local done, err = pcall(function()
      for _, is_json in ipairs({ true, false }) do
        view.show({ "200 OK", "", "body" }, { split = "vsplit", body_start = 3, is_json = is_json })
        local resp = vim.fn.bufnr("runtime-analysis://response")
        local win
        for _, w in ipairs(vim.api.nvim_list_wins()) do
          if vim.api.nvim_win_get_buf(w) == resp then
            win = w
          end
        end
        ok(
          win ~= nil,
          "view.show: a window shows the response (is_json=" .. tostring(is_json) .. ")"
        )
        eq(
          default_folds(win),
          before,
          "view.show: fold options are window-local (is_json=" .. tostring(is_json) .. ")"
        )

        -- a buffer first shown in the response window must not inherit the response's folding
        vim.api.nvim_set_current_win(win)
        vim.cmd("enew")
        eq(
          vim.wo.foldmethod .. "/" .. tostring(vim.wo.foldenable),
          before,
          "view.show: a buffer later opened in the response window starts with the default folding"
        )
        vim.cmd("bwipeout!")
        vim.api.nvim_set_current_win(origin)
        if vim.api.nvim_win_is_valid(win) then
          vim.api.nvim_win_close(win, true)
        end
      end
    end)

    -- Restore, also when an assertion above failed.
    vim.go.foldmethod, vim.go.foldenable = saved_fm, saved_fe
    if not done then
      error(err, 0)
    end
  end
end
