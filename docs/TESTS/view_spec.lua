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

  -- Clean up the split this spec opened, so a later spec's window layout
  -- assumptions are not disturbed by it.
  if winid_after_second and vim.api.nvim_win_is_valid(winid_after_second) then
    vim.api.nvim_win_close(winid_after_second, true)
  end
end
