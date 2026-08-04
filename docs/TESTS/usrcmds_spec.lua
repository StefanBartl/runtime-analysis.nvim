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

  ---A server that waits `delay_ms` after receiving a request before
  ---replying, so a test can deterministically fire a second send or a
  ---`:RA cancel` while the first is still genuinely in flight, without a
  ---race. The reply body echoes the request path (`reply-for-/a`) so a
  ---test can tell which of several in-flight requests' response actually
  ---rendered.
  ---@param delay_ms integer
  ---@return integer port
  ---@return uv_tcp_t server
  ---@return string[] requests
  local function start_delayed_server(delay_ms)
    local requests = {}
    local server = uv.new_tcp()
    assert(server:bind("127.0.0.1", 0))
    local port = server:getsockname().port
    server:listen(128, function(listen_err)
      assert(not listen_err, listen_err)
      local client = uv.new_tcp()
      server:accept(client)
      client:read_start(function(_, chunk)
        if not chunk then
          return
        end
        local method, path = chunk:match("^(%a+)%s+(%S+)")
        requests[#requests + 1] = ("%s %s"):format(method, path)
        vim.defer_fn(function()
          local body = "reply-for-" .. path
          client:write(table.concat({
            "HTTP/1.1 200 OK",
            "Content-Length: " .. #body,
            "",
            body,
          }, "\r\n"))
          client:shutdown(function()
            client:close()
          end)
        end, delay_ms)
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

  -- Declared here, not inside their own `do` blocks below: each is deleted
  -- only once at the very end (see the note by the first `close()` below
  -- for why), which needs them to still be in scope down there.
  local slow_buf, race_buf, cancel_buf

  -- Non-blocking (docs/ROADMAP.md §1.1): :RA send must return control
  -- before the response arrives, showing a pending placeholder in the
  -- meantime rather than leaving the pane looking untouched.
  do
    local slow_port, slow_server, slow_requests = start_delayed_server(150)
    slow_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(slow_buf, 0, -1, false, {
      ("GET http://127.0.0.1:%d/slow"):format(slow_port),
      "",
    })
    vim.api.nvim_win_set_buf(winid, slow_buf)
    vim.api.nvim_win_set_cursor(winid, { 1, 0 })

    vim.cmd("RA send")

    local resp_bufnr = vim.fn.bufnr("runtime-analysis://response")
    local placeholder = vim.api.nvim_buf_get_lines(resp_bufnr, 0, 1, false)[1]
    ok(
      placeholder:match("^→ sending") ~= nil,
      "usrcmds: :RA send shows a pending placeholder immediately, before the response arrives"
    )

    vim.wait(1000, function()
      return #slow_requests == 1
    end, 10)
    vim.wait(1000, function()
      return vim.api.nvim_buf_get_lines(resp_bufnr, 0, 1, false)[1] == "200 OK"
    end, 20)
    eq(
      vim.api.nvim_buf_get_lines(resp_bufnr, 0, 1, false)[1],
      "200 OK",
      "usrcmds: the real response eventually replaces the placeholder"
    )

    -- Not buf_delete'd here: `winid` still shows `slow_buf`, and deleting
    -- the buffer a window is currently displaying closes that window
    -- (verified — surprising, but real) when a second window exists, which
    -- the response split always does by this point. Deleted at the very
    -- end instead, once `winid` has moved on to something else.
    slow_server:close()
  end

  -- Supersession: a second :RA send fired before the first's response has
  -- arrived must discard the first's result — never a queue, never both
  -- rendering, and never a "request already in flight" refusal.
  do
    local race_port, race_server, race_requests = start_delayed_server(150)
    race_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(race_buf, 0, -1, false, {
      ("GET http://127.0.0.1:%d/a"):format(race_port),
      "",
      "###",
      ("GET http://127.0.0.1:%d/b"):format(race_port),
      "",
    })
    vim.api.nvim_win_set_buf(winid, race_buf)

    vim.api.nvim_win_set_cursor(winid, { 1, 0 })
    vim.cmd("RA send")
    vim.api.nvim_win_set_cursor(winid, { 4, 0 })
    vim.cmd("RA send")

    vim.wait(1000, function()
      return #race_requests == 2
    end, 10)
    ok(race_requests[1]:match("/a$") ~= nil, "usrcmds: the first request still actually went out")
    ok(race_requests[2]:match("/b$") ~= nil, "usrcmds: ... and so did the second")

    local resp_bufnr = vim.fn.bufnr("runtime-analysis://response")
    vim.wait(1000, function()
      local last = vim.api.nvim_buf_get_lines(resp_bufnr, -2, -1, false)[1]
      return last == "reply-for-/b"
    end, 20)
    eq(
      vim.api.nvim_buf_get_lines(resp_bufnr, -2, -1, false)[1],
      "reply-for-/b",
      "usrcmds: only the second send's response ever renders — the first's is discarded"
    )

    race_server:close()
  end

  -- :RA cancel: discards the in-flight request's eventual result, shows a
  -- cancelled message immediately, and a late, already-cancelled response
  -- must never overwrite that message when it finally arrives.
  do
    local cancel_port, cancel_server, cancel_requests = start_delayed_server(200)
    cancel_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(cancel_buf, 0, -1, false, {
      ("GET http://127.0.0.1:%d/cancel-me"):format(cancel_port),
      "",
    })
    vim.api.nvim_win_set_buf(winid, cancel_buf)
    vim.api.nvim_win_set_cursor(winid, { 1, 0 })

    vim.cmd("RA send")
    vim.cmd("RA cancel")

    local resp_bufnr = vim.fn.bufnr("runtime-analysis://response")
    eq(
      vim.api.nvim_buf_get_lines(resp_bufnr, 0, 1, false)[1],
      "✗ cancelled",
      "usrcmds: :RA cancel shows a cancelled message immediately"
    )

    -- Cancelling again with nothing in flight warns rather than erroring.
    local warned
    local orig_notify = vim.notify
    vim.notify = function(msg, level)
      warned = { msg = msg, level = level }
    end
    vim.cmd("RA cancel")
    vim.notify = orig_notify
    ok(warned ~= nil, "usrcmds: :RA cancel with nothing in flight warns instead of erroring")
    eq(warned.level, vim.log.levels.WARN, "usrcmds: ... at WARN level")

    -- The original request's late reply still arrives at the server-facing
    -- side (curl was never actually killed — see runner.run_async's own
    -- doc-comment on why) but must not reach the response pane.
    vim.wait(1000, function()
      return #cancel_requests == 1
    end, 10)
    vim.wait(500, function()
      return false
    end, 20) -- let the delayed reply actually land before checking
    eq(
      vim.api.nvim_buf_get_lines(resp_bufnr, 0, 1, false)[1],
      "✗ cancelled",
      "usrcmds: the cancelled request's late response never overwrites the cancelled state"
    )

    cancel_server:close()
  end

  -- :RA send records a history entry; :RA history clear empties it again.
  -- `history_spec.lua` covers `runtime-analysis.history`'s own behavior in
  -- detail against an isolated cache dir — this only checks that
  -- `bindings/usrcmds.lua` actually calls into it, using the real default
  -- dir the command path always uses (sandboxed-safe in this test
  -- environment; the same default dir every other real entry point uses).
  local history_buf
  do
    local history = require("runtime-analysis.history")
    history.clear() -- start from a clean slate for this project's key

    -- `start_server` (defined above) takes no response argument — it
    -- always answers 200 OK, which is exactly what this test asserts on.
    local hist_port, hist_server = start_server()
    history_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(history_buf, 0, -1, false, {
      ("GET http://127.0.0.1:%d/history-me"):format(hist_port),
      "",
    })
    vim.api.nvim_win_set_buf(winid, history_buf)
    vim.api.nvim_win_set_cursor(winid, { 1, 0 })

    vim.cmd("RA send")
    vim.wait(1000, function()
      local entries = history.list()
      return #entries == 1
    end, 10)

    local entries = history.list()
    eq(#entries, 1, "usrcmds: :RA send recorded exactly one history entry")
    eq(entries[1].method, "GET", "usrcmds: ... the method actually sent")
    ok(entries[1].url:match("/history%-me$") ~= nil, "usrcmds: ... and the url actually sent")
    eq(entries[1].status, 200, "usrcmds: ... with the real response status")

    vim.cmd("RA history clear")
    eq(#history.list(), 0, "usrcmds: :RA history clear empties this project's history")

    hist_server:close()
  end

  ---A server that always replies with `response` verbatim — for asserting
  ---on a specific HTTP status without the delayed-server's request-
  ---echoing machinery, which this doesn't need.
  ---@param response string
  ---@return integer port
  ---@return uv_tcp_t server
  local function start_fixed_server(response)
    local fixed_server = uv.new_tcp()
    assert(fixed_server:bind("127.0.0.1", 0))
    local fixed_port = fixed_server:getsockname().port
    fixed_server:listen(128, function(listen_err)
      assert(not listen_err, listen_err)
      local client = uv.new_tcp()
      fixed_server:accept(client)
      client:read_start(function(_, chunk)
        if chunk then
          client:write(response)
          client:shutdown(function()
            client:close()
          end)
        end
      end)
    end)
    return fixed_port, fixed_server
  end

  ---A server that records the *full* raw bytes of every request it
  ---accepts (headers and body, not just the request line — `start_server`
  ---above only needs the line), so a test can inspect what
  ---`resolve_request_shape` actually put on the wire.
  ---@return integer port
  ---@return uv_tcp_t server
  ---@return string[] raw_requests
  local function start_capturing_server()
    local raw_requests = {}
    local capture_server = uv.new_tcp()
    assert(capture_server:bind("127.0.0.1", 0))
    local capture_port = capture_server:getsockname().port
    capture_server:listen(128, function(listen_err)
      assert(not listen_err, listen_err)
      local client = uv.new_tcp()
      capture_server:accept(client)
      client:read_start(function(_, chunk)
        if chunk then
          raw_requests[#raw_requests + 1] = chunk
        end
        client:write(table.concat({ "HTTP/1.1 200 OK", "", "" }, "\r\n"))
        client:shutdown(function()
          client:close()
        end)
      end)
    end)
    return capture_port, capture_server, raw_requests
  end

  -- GraphQL (docs/ROADMAP.md §2.6): a real :RA send against the
  -- X-Request-Type: GraphQL shorthand puts the real {"query":...,
  -- "variables":...} JSON on the wire, not the shorthand shape.
  local graphql_buf
  do
    local gql_port, gql_server, gql_requests = start_capturing_server()
    graphql_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(graphql_buf, 0, -1, false, {
      ("POST http://127.0.0.1:%d/graphql"):format(gql_port),
      "X-Request-Type: GraphQL",
      "Content-Type: application/json",
      "",
      "query GetUser($id: ID!) {",
      "  user(id: $id) { name }",
      "}",
      "",
      '{"id": "42"}',
    })
    vim.api.nvim_win_set_buf(winid, graphql_buf)
    vim.api.nvim_win_set_cursor(winid, { 1, 0 })

    vim.cmd("RA send")
    vim.wait(1000, function()
      return #gql_requests > 0
    end, 10)

    eq(#gql_requests, 1, "usrcmds: :RA send on a GraphQL block made exactly one request")
    local raw = gql_requests[1]
    ok(
      raw:find("X-Request-Type", 1, true) == nil,
      "usrcmds: the X-Request-Type header never reached the wire"
    )
    ok(raw:find('"query":"query GetUser', 1, true) ~= nil, "usrcmds: the real query is in the body")
    ok(raw:find('"id":"42"', 1, true) ~= nil, "usrcmds: the real variable value is in the body")

    gql_server:close()
  end

  -- Multipart (docs/ROADMAP.md §2.6): a real :RA send against a
  -- multipart body with a `< ./path` file reference puts the real file
  -- bytes on the wire.
  local multipart_buf
  do
    local upload_path = H.tmpfile(".txt")
    local upload_f = assert(io.open(upload_path, "wb"))
    upload_f:write("real-file-bytes-for-upload")
    upload_f:close()
    local upload_dir = vim.fn.fnamemodify(upload_path, ":h")
    local upload_name = vim.fn.fnamemodify(upload_path, ":t")

    local mp_port, mp_server, mp_requests = start_capturing_server()
    local boundary = "----WebKitFormBoundary7MA4YWxkTrZu0gW"
    multipart_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(multipart_buf, 0, -1, false, {
      ("POST http://127.0.0.1:%d/upload"):format(mp_port),
      "Content-Type: multipart/form-data; boundary=" .. boundary,
      "",
      "--" .. boundary,
      'Content-Disposition: form-data; name="file"; filename="' .. upload_name .. '"',
      "",
      "< ./" .. upload_name,
      "--" .. boundary .. "--",
    })
    -- A real file path, not a scratch buffer: `request_base_dir` resolves
    -- `< ./path` against the buffer's own directory, so this must be a
    -- real, named buffer for the relative reference above to find it.
    vim.api.nvim_buf_set_name(multipart_buf, upload_dir .. "/multipart_spec_request.http")
    vim.api.nvim_win_set_buf(winid, multipart_buf)
    vim.api.nvim_win_set_cursor(winid, { 1, 0 })

    vim.cmd("RA send")
    vim.wait(1000, function()
      return #mp_requests > 0
    end, 10)

    eq(#mp_requests, 1, "usrcmds: :RA send on a multipart block made exactly one request")
    ok(
      mp_requests[1]:find("real-file-bytes-for-upload", 1, true) ~= nil,
      "usrcmds: the real file's own bytes are in the body, not the < path marker"
    )

    mp_server:close()
    os.remove(upload_path)
  end

  -- Response assertions (docs/ROADMAP.md §2.5): a passing `@expect status
  -- N` leaves the quickfix list alone; a mismatch populates it with an
  -- entry pointing back at the directive's own line.
  local assert_pass_buf, assert_fail_buf
  do
    local pass_port, pass_server = start_server() -- always replies 200 OK
    assert_pass_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(assert_pass_buf, 0, -1, false, {
      "# @expect status 200",
      ("GET http://127.0.0.1:%d/expect-ok"):format(pass_port),
      "",
    })
    vim.api.nvim_win_set_buf(winid, assert_pass_buf)
    vim.api.nvim_win_set_cursor(winid, { 1, 0 })

    vim.fn.setqflist({}, "r") -- start from an empty list
    local resp_bufnr = vim.fn.bufnr("runtime-analysis://response")
    vim.cmd("RA send")
    vim.wait(1000, function()
      return vim.api.nvim_buf_get_lines(resp_bufnr, 0, 1, false)[1] == "200 OK"
    end, 10)
    eq(#vim.fn.getqflist(), 0, "usrcmds: a passing @expect status leaves the quickfix list empty")

    pass_server:close()
  end

  do
    local fail_port, fail_server =
      start_fixed_server(table.concat({ "HTTP/1.1 404 Not Found", "", "" }, "\r\n"))
    assert_fail_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(assert_fail_buf, 0, -1, false, {
      "# @expect status 200",
      ("GET http://127.0.0.1:%d/expect-fail"):format(fail_port),
      "",
    })
    vim.api.nvim_win_set_buf(winid, assert_fail_buf)
    vim.api.nvim_win_set_cursor(winid, { 1, 0 })

    vim.fn.setqflist({}, "r")
    local resp_bufnr = vim.fn.bufnr("runtime-analysis://response")
    vim.cmd("RA send")
    vim.wait(1000, function()
      return vim.api.nvim_buf_get_lines(resp_bufnr, 0, 1, false)[1] == "404 Not Found"
    end, 10)
    vim.wait(200, function()
      return #vim.fn.getqflist() > 0
    end, 10)

    local qf = vim.fn.getqflist()
    eq(#qf, 1, "usrcmds: a failed @expect status populates the quickfix list with one entry")
    eq(qf[1].bufnr, assert_fail_buf, "usrcmds: the quickfix entry points at the request buffer")
    eq(qf[1].lnum, 1, "usrcmds: ... at the @expect directive's own line")
    ok(
      qf[1].text:find("200", 1, true) ~= nil and qf[1].text:find("404", 1, true) ~= nil,
      "usrcmds: the quickfix text names both the expected and actual status"
    )

    fail_server:close()
  end

  vim.api.nvim_win_set_buf(winid, prev_buf)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  vim.api.nvim_buf_delete(slow_buf, { force = true })
  vim.api.nvim_buf_delete(race_buf, { force = true })
  vim.api.nvim_buf_delete(cancel_buf, { force = true })
  vim.api.nvim_buf_delete(assert_pass_buf, { force = true })
  vim.api.nvim_buf_delete(assert_fail_buf, { force = true })
  vim.api.nvim_buf_delete(graphql_buf, { force = true })
  vim.api.nvim_buf_delete(multipart_buf, { force = true })
end
