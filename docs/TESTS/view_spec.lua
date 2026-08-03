-- docs/TESTS/view_spec.lua — runtime-analysis.view
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

  -- Clean up the split this spec opened, so a later spec's window layout
  -- assumptions are not disturbed by it.
  if winid_after_second and vim.api.nvim_win_is_valid(winid_after_second) then
    vim.api.nvim_win_close(winid_after_second, true)
  end
end
