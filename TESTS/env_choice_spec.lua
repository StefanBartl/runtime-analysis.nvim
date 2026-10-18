---@diagnostic disable: need-check-nil
-- TESTS/env_choice_spec.lua -- a request with `{{var}}` and no selected environment offers the environments to pick from
-- (instead of telling the person to run `:RA env <name>`), sets the choice and sends; dismissing sends nothing.

return function(H)
  local eq, ok = H.eq, H.ok
  local uv = vim.uv or vim.loop
  local env = require("runtime-analysis.env")

  require("runtime-analysis").setup({})

  ---@return integer port
  ---@return uv.uv_tcp_t server
  ---@return string[] requests
  local function start_server()
    local requests = {}
    local server = assert(uv.new_tcp())
    assert(server:bind("127.0.0.1", 0))
    local port = server:getsockname().port
    server:listen(128, function(listen_err)
      assert(not listen_err, listen_err)
      local client = assert(uv.new_tcp())
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

  -- a project folder (a git root) with two environments, entered for the length of the spec
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir .. "/.git", "p")
  local port, server, requests = start_server()
  local f = assert(io.open(dir .. "/" .. env.SHARED_FILE, "w"))
  f:write(vim.json.encode({
    dev = { baseUrl = ("http://127.0.0.1:%d"):format(port) },
    other = { baseUrl = "http://127.0.0.1:1" },
  }))
  f:close()
  local old_cwd = vim.fn.getcwd()
  vim.cmd("cd " .. vim.fn.fnameescape(dir))

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "GET {{baseUrl}}/picked", "" })
  vim.api.nvim_win_set_buf(0, bufnr)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })

  local offered
  local choice
  env.select = function(names, _opts, cb)
    offered = names
    cb(choice)
  end

  -- the third return value says it is only the environment that is missing
  env._reset_for_test()
  local _, _, reason = env.resolve({ method = "GET", url = "{{baseUrl}}/x", headers = {} })
  eq(reason, "no_environment", "resolve: a missing selection is told apart from a missing variable")

  -- dismissed: nothing is sent, nothing is selected
  env._reset_for_test()
  offered, choice = nil, nil
  vim.cmd("RA send")
  vim.wait(300, function()
    return false
  end, 10)
  eq(offered and table.concat(offered, ","), "dev,other", "the environments there are are offered")
  eq(#requests, 0, "a dismissed choice sends nothing")
  eq(env.current(), nil, "and selects nothing")

  -- picked: selected, and the request goes out with it
  env._reset_for_test()
  choice = "dev"
  vim.cmd("RA send")
  vim.wait(2000, function()
    return #requests >= 1
  end, 10)
  eq(env.current(), "dev", "the choice becomes the environment of the session")
  eq(#requests, 1, "and the request is sent")
  ok(requests[1] and requests[1]:match("/picked$") ~= nil, "resolved with the chosen environment")

  -- an environment is selected already: nothing is asked
  offered = nil
  vim.cmd("RA send")
  vim.wait(2000, function()
    return #requests >= 2
  end, 10)
  eq(offered, nil, "with an environment selected nothing is offered")

  -- no environments defined at all: the message stays, nothing is offered
  env._reset_for_test()
  os.remove(dir .. "/" .. env.SHARED_FILE)
  offered = nil
  local before = #requests
  local sent, told = pcall(vim.cmd, "RA send")
  vim.wait(200, function()
    return false
  end, 10)
  ok(
    not sent and tostring(told):find("no environment is selected", 1, true) ~= nil,
    "the old message is what is left when there is nothing to pick"
  )
  eq(offered, nil, "nothing to offer when no environment is defined")
  eq(#requests, before, "and nothing is sent")

  env.select = nil
  env._reset_for_test()
  vim.cmd("cd " .. vim.fn.fnameescape(old_cwd))
  server:close()
end
