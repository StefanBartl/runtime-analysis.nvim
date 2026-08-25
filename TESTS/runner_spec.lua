-- TESTS/runner_spec.lua — runtime-analysis.runner
--
-- Same hermetic pattern lib.nvim's own TESTS/curl_spec.lua uses: a
-- tiny `vim.uv` TCP server answers with a hand-crafted raw HTTP response,
-- so this exercises the real `lib.nvim.net.curl.fetch_raw_blocking` call
-- underneath `runner.run` against real sockets, no external test
-- dependency and no mock standing in for curl's own behavior.

return function(H)
  local eq, ok = H.eq, H.ok
  local runner = require("runtime-analysis.runner")
  local uv = vim.uv or vim.loop

  ---@param response string
  ---@return integer port
  ---@return uv_tcp_t server
  local function start_server(response)
    local server = uv.new_tcp()
    assert(server:bind("127.0.0.1", 0))
    local port = server:getsockname().port
    server:listen(128, function(listen_err)
      assert(not listen_err, listen_err)
      local client = uv.new_tcp()
      server:accept(client)
      client:read_start(function(_, _)
        client:write(response)
        client:shutdown(function()
          client:close()
        end)
      end)
    end)
    return port, server
  end

  -- A real 200 with a header and a JSON body: the body is now pretty-printed
  -- (docs/ROADMAP.md §2.2) rather than shown compact, and `meta` reports
  -- where the body starts and that it is JSON.
  do
    local port, server = start_server(table.concat({
      "HTTP/1.1 200 OK",
      "Content-Type: application/json",
      "",
      '{"ok":true}',
    }, "\r\n"))

    local lines, err, meta = runner.run({
      method = "GET",
      url = ("http://127.0.0.1:%d/"):format(port),
      headers = {},
    })
    eq(err, nil, "runner.run: no error on a real 200")
    eq(lines[1], "200 OK", "runner.run: first line is the real status")
    eq(lines[2], "content-type: application/json", "runner.run: headers next, lowercased")
    eq(lines[3], "", "runner.run: a blank line separates headers from body")
    eq(
      table.concat(lines, "|", 4, #lines),
      '{|  "ok": true|}',
      "runner.run: a json content-type body is pretty-printed, not shown compact"
    )
    ok(meta ~= nil, "runner.run: meta is returned alongside lines")
    eq(meta.body_start, 4, "runner.run: meta.body_start points at the first body line")
    eq(meta.is_json, true, "runner.run: meta.is_json true for a real json body")

    server:close()
  end

  -- A `Content-Type: application/json` header is a claim, not a guarantee —
  -- a body that does not actually decode as JSON must render verbatim
  -- rather than error or drop content.
  do
    local port, server = start_server(table.concat({
      "HTTP/1.1 200 OK",
      "Content-Type: application/json",
      "",
      "not actually json",
    }, "\r\n"))

    local lines, _, meta = runner.run({
      method = "GET",
      url = ("http://127.0.0.1:%d/"):format(port),
    })
    eq(lines[4], "not actually json", "runner.run: malformed json falls back to the raw body")
    eq(meta.is_json, false, "runner.run: meta.is_json false when decoding failed")

    server:close()
  end

  -- Headers sorted, so the same response renders identically across runs —
  -- a diff between two responses should be about the *data*, not about
  -- table iteration order. Also: no Content-Type at all means no
  -- pretty-printing is even attempted, verbatim body as always.
  do
    local port, server = start_server(table.concat({
      "HTTP/1.1 200 OK",
      "Z-Header: last-alphabetically",
      "A-Header: first-alphabetically",
      "",
      "body",
    }, "\r\n"))

    local lines, _, meta =
      runner.run({ method = "GET", url = ("http://127.0.0.1:%d/"):format(port) })
    ok(
      lines[2]:match("^a%-header") ~= nil,
      "runner.run: headers sorted by name, not left in arrival order"
    )
    eq(lines[3]:match("^z%-header"), "z-header", "runner.run: ... the other one comes second")
    eq(lines[5], "body", "runner.run: body verbatim with no Content-Type header at all")
    eq(meta.is_json, false, "runner.run: meta.is_json false with no Content-Type header")

    server:close()
  end

  -- An unreachable target: runner.run must report the error, not raise.
  do
    local port, server = start_server("")
    server:close()
    vim.wait(50, function()
      return false
    end, 10)

    local lines, err = runner.run({
      method = "GET",
      url = ("http://127.0.0.1:%d/"):format(port),
    })
    eq(lines, nil, "runner.run: no lines when curl itself failed")
    ok(type(err) == "string", "runner.run: ... a real error string instead")
  end

  -- runner.run_async (docs/ROADMAP.md §1.1) — same formatting as runner.run,
  -- reached non-blockingly, with a callback guaranteed to run outside the
  -- fast-event context `lib.nvim.net.curl.fetch_raw`'s own callback fires
  -- in (verified once, in `bindings/usrcmds.lua`'s own doc-comment; checked
  -- again here directly rather than trusted).
  do
    local port, server = start_server(table.concat({
      "HTTP/1.1 201 Created",
      "Content-Type: application/json",
      "",
      '{"id":1}',
    }, "\r\n"))

    local called = false
    local got_lines, got_err, got_meta
    runner.run_async({
      method = "POST",
      url = ("http://127.0.0.1:%d/"):format(port),
      headers = {},
      body = '{"id":1}',
    }, function(lines, err, meta)
      -- The one thing every caller of run_async needs to be able to rely
      -- on without remembering it themselves: this runs somewhere a real
      -- buffer/window API call is legal.
      local ok_buf = pcall(vim.api.nvim_create_buf, false, true)
      ok(ok_buf, "runner.run_async: callback runs outside the fast-event context")
      called = true
      got_lines, got_err, got_meta = lines, err, meta
    end)

    -- Genuinely non-blocking: the call above must have returned before the
    -- callback fired — otherwise this is `runner.run` with extra steps.
    eq(called, false, "runner.run_async: does not call back synchronously")

    vim.wait(1000, function()
      return called
    end, 10)

    ok(called, "runner.run_async: the callback eventually fires")
    eq(got_err, nil, "runner.run_async: no error on a real 201")
    eq(got_lines[1], "201 Created", "runner.run_async: same formatting as runner.run")
    eq(
      table.concat(got_lines, "|", 4, #got_lines),
      '{|  "id": 1|}',
      "runner.run_async: json body pretty-printed, same as the blocking path"
    )
    eq(got_meta.is_json, true, "runner.run_async: meta reported the same way too")

    server:close()
  end

  -- runner.run_async on a curl failure: the callback still fires, still
  -- scheduled, with `lines == nil` and a real error string — the async
  -- twin of the "unreachable target" case above.
  do
    local port, server = start_server("")
    server:close()
    vim.wait(50, function()
      return false
    end, 10)

    local called = false
    local got_lines, got_err
    runner.run_async({
      method = "GET",
      url = ("http://127.0.0.1:%d/"):format(port),
    }, function(lines, err)
      called = true
      got_lines, got_err = lines, err
    end)

    -- A closed local port still takes real time to report "connection
    -- refused" — measured up to ~2s on this environment (Windows' TCP
    -- stack retries before giving up, unlike Linux's near-instant RST) —
    -- so this waits longer than the success-path tests above need to.
    vim.wait(5000, function()
      return called
    end, 20)

    ok(called, "runner.run_async: callback fires on failure too")
    eq(got_lines, nil, "runner.run_async: no lines when curl itself failed")
    ok(type(got_err) == "string", "runner.run_async: ... a real error string instead")
  end
end
