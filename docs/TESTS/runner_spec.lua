-- docs/TESTS/runner_spec.lua — runtime-analysis.runner
--
-- Same hermetic pattern lib.nvim's own docs/TESTS/curl_spec.lua uses: a
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

  -- A real 200 with a header and a JSON body.
  do
    local port, server = start_server(table.concat({
      "HTTP/1.1 200 OK",
      "Content-Type: application/json",
      "",
      '{"ok":true}',
    }, "\r\n"))

    local lines = runner.run({
      method = "GET",
      url = ("http://127.0.0.1:%d/"):format(port),
      headers = {},
    })
    eq(lines[1], "200 OK", "runner.run: first line is the real status")
    eq(lines[2], "content-type: application/json", "runner.run: headers next, lowercased")
    eq(lines[3], "", "runner.run: a blank line separates headers from body")
    eq(lines[4], '{"ok":true}', "runner.run: body is the raw text, no reformatting attempted")

    server:close()
  end

  -- Headers sorted, so the same response renders identically across runs —
  -- a diff between two responses should be about the *data*, not about
  -- table iteration order.
  do
    local port, server = start_server(table.concat({
      "HTTP/1.1 200 OK",
      "Z-Header: last-alphabetically",
      "A-Header: first-alphabetically",
      "",
      "body",
    }, "\r\n"))

    local lines = runner.run({ method = "GET", url = ("http://127.0.0.1:%d/"):format(port) })
    ok(
      lines[2]:match("^a%-header") ~= nil,
      "runner.run: headers sorted by name, not left in arrival order"
    )
    eq(lines[3]:match("^z%-header"), "z-header", "runner.run: ... the other one comes second")

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
end
