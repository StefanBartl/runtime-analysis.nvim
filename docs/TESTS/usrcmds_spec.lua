-- docs/TESTS/usrcmds_spec.lua — runtime-analysis.bindings.usrcmds
--
-- `parse_spec.lua` covers `split`/`block_at` as pure logic; this covers the
-- actual wiring in `send_current_buffer` — a real multi-block buffer, a
-- real cursor position, a real `:RA send`, against a hermetic local server
-- (same pattern `runner_spec.lua` uses), verifying the *right* block was
-- the one actually sent rather than assuming the pure-logic tests prove it.

return function(H)
  local eq, ok = H.eq, H.ok
  local uv = vim.uv or vim.loop

  require("runtime-analysis").setup({})

  ---A server that records the request line of every connection it accepts,
  ---in arrival order, and answers each with a minimal 200. `requests` is
  ---returned live (the same table further connections append to), so a
  ---test can inspect it after each send without re-wiring the callback.
  ---@return integer port
  ---@return uv_tcp_t server
  ---@return string[] requests
  local function start_server()
    local requests = {}
    local server = uv.new_tcp()
    assert(server:bind("127.0.0.1", 0))
    local port = server:getsockname().port
    server:listen(128, function(listen_err)
      assert(not listen_err, listen_err)
      local client = uv.new_tcp()
      server:accept(client)
      client:read_start(function(_, chunk)
        if chunk then
          requests[#requests + 1] = chunk:match("^(%a+%s+%S+)")
        end
        client:write(table.concat({ "HTTP/1.1 200 OK", "", "" }, "\r\n"))
        client:shutdown(function()
          client:close()
        end)
      end)
    end)
    return port, server, requests
  end

  local port, server, requests = start_server()

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    ("GET http://127.0.0.1:%d/first"):format(port),
    "",
    "###",
    ("GET http://127.0.0.1:%d/second"):format(port),
    "",
  })
  local winid = vim.api.nvim_get_current_win()
  local prev_buf = vim.api.nvim_win_get_buf(winid)
  vim.api.nvim_win_set_buf(winid, bufnr)

  -- Cursor on block 1 (line 1): :RA send must hit /first, not /second.
  vim.api.nvim_win_set_cursor(winid, { 1, 0 })
  vim.cmd("RA send")
  vim.wait(500, function()
    return #requests == 1
  end, 10)
  ok(#requests == 1, "usrcmds: :RA send made exactly one request for block 1")
  ok(requests[1]:match("/first$") ~= nil, "usrcmds: cursor in block 1 sends block 1, not block 2")

  -- Cursor on block 2 (line 4): :RA send must hit /second this time.
  vim.api.nvim_win_set_cursor(winid, { 4, 0 })
  vim.cmd("RA send")
  vim.wait(500, function()
    return #requests == 2
  end, 10)
  eq(#requests, 2, "usrcmds: a second :RA send made exactly one more request")
  ok(
    requests[2]:match("/second$") ~= nil,
    "usrcmds: cursor in block 2 sends block 2, not block 1 again"
  )

  -- `:RASend`, the flat alias, must resolve the same way — same handler,
  -- not a second, divergent implementation.
  vim.api.nvim_win_set_cursor(winid, { 1, 0 })
  vim.cmd("RASend")
  vim.wait(500, function()
    return #requests == 3
  end, 10)
  eq(#requests, 3, "usrcmds: :RASend (flat alias) also made exactly one request")
  ok(
    requests[3]:match("/first$") ~= nil,
    "usrcmds: ... and resolves the cursor the same way :RA send does"
  )

  server:close()
  vim.api.nvim_win_set_buf(winid, prev_buf)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end
