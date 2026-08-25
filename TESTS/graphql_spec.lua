-- TESTS/graphql_spec.lua — runtime-analysis.graphql (docs/ROADMAP.md
-- §2.6)
--
-- Pure logic: a parsed request in, either an unchanged request (not
-- GraphQL) or the real POST+JSON it resolves to (GraphQL) out.

return function(H)
  local eq, ok = H.eq, H.ok
  local graphql = require("runtime-analysis.graphql")

  -- is_graphql: header name and value both matched case-insensitively —
  -- real HTTP header semantics, not a literal-string convenience.
  do
    ok(
      graphql.is_graphql({ ["X-Request-Type"] = "GraphQL" }),
      "is_graphql: the exact-case header matches"
    )
    ok(
      graphql.is_graphql({ ["x-request-type"] = "graphql" }),
      "is_graphql: lower-cased name and value both still match"
    )
    ok(
      not graphql.is_graphql({ ["Content-Type"] = "application/json" }),
      "is_graphql: an ordinary request is not GraphQL"
    )
    ok(not graphql.is_graphql({}), "is_graphql: no headers at all is not GraphQL")
  end

  -- resolve: a non-GraphQL request passes through completely unchanged —
  -- the common case, untouched by this feature existing.
  do
    local request = {
      method = "POST",
      url = "https://api.example.com/users",
      headers = { ["Content-Type"] = "application/json" },
      body = '{"name":"Alice"}',
    }
    local resolved, err = graphql.resolve(request)
    eq(err, nil, "resolve: no error for an ordinary request")
    eq(resolved, request, "resolve: an ordinary request is returned unchanged")
  end

  -- resolve: no body at all -- a no-op, not an error; the actual "no body
  -- to send" case is a different, more useful error elsewhere in the
  -- pipeline.
  do
    local request = {
      method = "POST",
      url = "https://api.example.com/graphql",
      headers = { ["X-Request-Type"] = "GraphQL" },
      body = nil,
    }
    local resolved, err = graphql.resolve(request)
    eq(err, nil, "resolve: no error when a GraphQL request simply has no body")
    eq(resolved, request, "resolve: unchanged when there is no body to build a query from")
  end

  -- resolve: query only, no variables block at all (no blank line in the
  -- body) -- the header is still stripped, variables encode as {}, not
  -- null or omitted.
  do
    local request = {
      method = "POST",
      url = "https://api.example.com/graphql",
      headers = { ["X-Request-Type"] = "GraphQL", ["Content-Type"] = "application/json" },
      body = "query { viewer { name } }",
    }
    local resolved, err = graphql.resolve(request)
    eq(err, nil, "resolve: no error for a query-only GraphQL request")
    assert(resolved, "resolve: succeeds for a query-only GraphQL request")
    eq(
      resolved.headers["X-Request-Type"],
      nil,
      "resolve: the X-Request-Type header is consumed, never forwarded"
    )
    eq(
      resolved.headers["Content-Type"],
      "application/json",
      "resolve: every other header passes through untouched"
    )
    local decoded = vim.json.decode(resolved.body)
    eq(decoded.query, "query { viewer { name } }", "resolve: the query text, verbatim")
    ok(
      resolved.body:find('"variables":{}', 1, true) ~= nil,
      "resolve: variables encodes as an empty object ({}), not null or omitted"
    )
    ok(
      decoded.variables ~= nil and vim.tbl_isempty(decoded.variables),
      "resolve: ... and round-trips back to a real, empty table"
    )
  end

  -- resolve: query + variables, blank-line separated -- REST Client's own
  -- rule, real multi-line query text included.
  do
    local body = table.concat({
      "query GetUser($id: ID!) {",
      "  user(id: $id) {",
      "    name",
      "  }",
      "}",
      "",
      '{"id": "42"}',
    }, "\n")
    local request = {
      method = "POST",
      url = "https://api.example.com/graphql",
      headers = { ["X-Request-Type"] = "GraphQL" },
      body = body,
    }
    local resolved = assert(graphql.resolve(request))
    local decoded = vim.json.decode(resolved.body)
    ok(
      decoded.query:find("GetUser", 1, true) ~= nil,
      "resolve: the real, multi-line query text made it through"
    )
    eq(decoded.variables.id, "42", "resolve: the real variable value made it through")
  end

  -- resolve: an invalid JSON variables block is a real, named error, not
  -- a silently empty variables object or a Lua error propagating up.
  do
    local request = {
      method = "POST",
      url = "https://api.example.com/graphql",
      headers = { ["X-Request-Type"] = "GraphQL" },
      body = "query { viewer { name } }\n\nnot json at all",
    }
    local resolved, err = graphql.resolve(request)
    eq(resolved, request, "resolve: the original request is returned alongside the error")
    ok(
      err and err:find("not valid JSON", 1, true) ~= nil,
      "resolve: a real error naming what is wrong"
    )
  end
end
