-- TESTS/env_spec.lua — runtime-analysis.env (docs/ROADMAP.md §2.1)
--
-- Every case passes `{ root = tmpdir }` so this never touches the real
-- project root or a real .gitignore — the same isolation history_spec.lua
-- gets from `opts.dir`. `env._reset_for_test()` drops the module-level
-- "currently selected environment" back to nil at the start of every `do`
-- block, so blocks stay independent of the order they run in.

return function(H)
  local eq, ok = H.eq, H.ok
  local env = require("runtime-analysis.env")

  ---@param dir string
  ---@param filename string
  ---@param tbl table
  local function write_json(dir, filename, tbl)
    vim.fn.mkdir(dir, "p")
    local f = assert(io.open(dir .. "/" .. filename, "w"))
    f:write(vim.json.encode(tbl))
    f:close()
  end

  -- No env files at all: an empty list, not an error.
  do
    env._reset_for_test()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    eq(#env.list_names({ root = dir }), 0, "list_names: empty project has no environments")
  end

  -- The shared file alone defines names and values.
  do
    env._reset_for_test()
    local dir = vim.fn.tempname()
    write_json(dir, env.SHARED_FILE, { dev = { baseUrl = "http://localhost:3000" } })

    local names = env.list_names({ root = dir })
    eq(#names, 1, "list_names: one environment from the shared file alone")
    eq(names[1], "dev", "list_names: ... named 'dev'")
  end

  -- Private file keys win over shared on overlap; keys unique to either
  -- side survive the merge.
  do
    env._reset_for_test()
    local dir = vim.fn.tempname()
    write_json(
      dir,
      env.SHARED_FILE,
      { dev = { baseUrl = "http://localhost:3000", shared_only = "s" } }
    )
    write_json(
      dir,
      env.PRIVATE_FILE,
      { dev = { baseUrl = "http://overridden:9999", token = "secret" } }
    )

    local vars = env.load_all({ root = dir }).dev
    eq(vars.baseUrl, "http://overridden:9999", "load_all: private file wins on overlap")
    eq(vars.shared_only, "s", "load_all: a shared-only key survives the merge")
    eq(vars.token, "secret", "load_all: a private-only key survives the merge")
  end

  -- set_current rejects an unknown name and leaves the selection unchanged.
  do
    env._reset_for_test()
    local dir = vim.fn.tempname()
    write_json(dir, env.SHARED_FILE, { dev = { baseUrl = "http://x" } })

    local ok1, err1 = env.set_current("nope", { root = dir })
    eq(ok1, false, "set_current: rejects an unknown environment name")
    ok(err1 and err1:find("dev", 1, true) ~= nil, "set_current: error names the available ones")
    eq(env.current(), nil, "set_current: selection stays nil after a rejected name")

    local ok2 = env.set_current("dev", { root = dir })
    eq(ok2, true, "set_current: accepts a name the files actually define")
    eq(env.current(), "dev", "current: reflects the accepted selection")
  end

  -- resolve: a request with no {{placeholders}} at all passes straight
  -- through, unchanged, even with no environment ever selected.
  do
    env._reset_for_test()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local request = { method = "GET", url = "https://api.example.com/x", headers = {} }

    local resolved, err = env.resolve(request, { root = dir })
    eq(err, nil, "resolve: no error for a plain request with no environment selected")
    assert(resolved, "resolve: a plain request resolves with no environment selected")
    eq(resolved.url, request.url, "resolve: url unchanged with nothing to substitute")
  end

  -- resolve: a placeholder with no environment selected is a clear error,
  -- not a silent pass-through of the literal "{{...}}".
  do
    env._reset_for_test()
    local dir = vim.fn.tempname()
    write_json(dir, env.SHARED_FILE, { dev = { baseUrl = "http://x" } })
    local request = { method = "GET", url = "{{baseUrl}}/users", headers = {} }

    local resolved, err = env.resolve(request, { root = dir })
    eq(resolved, nil, "resolve: nil result when no environment is selected")
    ok(err and err:find("baseUrl", 1, true) ~= nil, "resolve: error names the missing variable")
  end

  -- resolve: substitutes into url, header values and body; leaves the
  -- original `request` table itself completely untouched (the whole point
  -- — history/the "sending ..." placeholder must still see the literal
  -- `{{token}}`, per the roadmap entry's own stated trap).
  do
    env._reset_for_test()
    local dir = vim.fn.tempname()
    write_json(
      dir,
      env.SHARED_FILE,
      { dev = { baseUrl = "http://localhost:3000", token = "abc123" } }
    )
    env.set_current("dev", { root = dir })

    local request = {
      method = "POST",
      url = "{{baseUrl}}/users",
      headers = { Authorization = "Bearer {{token}}", ["Content-Type"] = "application/json" },
      body = '{"host":"{{baseUrl}}"}',
    }

    local resolved, err = env.resolve(request, { root = dir })
    eq(err, nil, "resolve: no error once the environment has every referenced variable")
    assert(resolved, "resolve: succeeds once the environment has every referenced variable")
    eq(resolved.url, "http://localhost:3000/users", "resolve: url substituted")
    eq(resolved.headers.Authorization, "Bearer abc123", "resolve: header value substituted")
    eq(
      resolved.headers["Content-Type"],
      "application/json",
      "resolve: a header with no placeholder is untouched"
    )
    eq(resolved.body, '{"host":"http://localhost:3000"}', "resolve: body substituted")

    eq(request.url, "{{baseUrl}}/users", "resolve: the original request's url is never mutated")
    eq(
      request.headers.Authorization,
      "Bearer {{token}}",
      "resolve: the original request's headers are never mutated"
    )
  end

  -- resolve: a variable the selected environment doesn't define is a named
  -- error, not a silent "{{name}}" left in the outgoing request.
  do
    env._reset_for_test()
    local dir = vim.fn.tempname()
    write_json(dir, env.SHARED_FILE, { dev = { baseUrl = "http://x" } })
    env.set_current("dev", { root = dir })

    local request = { method = "GET", url = "{{baseUrl}}/{{missing}}", headers = {} }
    local resolved, err = env.resolve(request, { root = dir })
    eq(
      resolved,
      nil,
      "resolve: nil result when a variable is undefined in the selected environment"
    )
    ok(err and err:find("missing", 1, true) ~= nil, "resolve: error names the undefined variable")
  end
end
