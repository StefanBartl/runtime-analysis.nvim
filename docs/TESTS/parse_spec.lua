-- docs/TESTS/parse_spec.lua — runtime-analysis.parse
--
-- Pure logic, no I/O: every case here is a plain buffer-lines array in,
-- a request table (or an error) out.

return function(H)
  local eq, ok = H.eq, H.ok
  local parse = require("runtime-analysis.parse")

  -- The common case: method, url, headers, a blank line, a body.
  do
    local req = parse.parse({
      "POST https://api.example.com/users",
      "Content-Type: application/json",
      "Authorization: Bearer abc123",
      "",
      '{"name":"Alice"}',
    })
    eq(req.method, "POST", "parse: method read from the request line")
    eq(req.url, "https://api.example.com/users", "parse: url read from the request line")
    eq(req.headers["Content-Type"], "application/json", "parse: a header parsed")
    eq(req.headers["Authorization"], "Bearer abc123", "parse: ... and another")
    eq(req.body, '{"name":"Alice"}', "parse: body is everything after the blank line, verbatim")
  end

  -- No headers, no body: just a request line.
  do
    local req = parse.parse({ "GET https://example.com/" })
    eq(req.method, "GET", "parse: bare request line, method")
    eq(req.url, "https://example.com/", "parse: bare request line, url")
    eq(next(req.headers), nil, "parse: no headers at all is an empty table, not nil")
    eq(req.body, nil, "parse: no blank line at all means no body")
  end

  -- A blank line present, but nothing meaningful after it: still no body —
  -- trailing whitespace-only lines are not a body any more than an absent
  -- blank line is.
  do
    local req = parse.parse({ "GET https://x", "", "", "  " })
    eq(req.body, nil, "parse: whitespace-only trailer is not a body")
  end

  -- Leading blank lines before the request line are tolerated — the first
  -- non-blank line is what counts, not strictly the first line.
  do
    local req = parse.parse({ "", "  ", "GET https://x" })
    eq(req.method, "GET", "parse: leading blank lines are skipped")
  end

  -- Error paths: each must report `nil` plus a real, specific message —
  -- never a crash, never a silently wrong guess.
  do
    local req, err = parse.parse({ "", "  ", "" })
    eq(req, nil, "parse: an all-blank buffer has no request")
    ok(err:match("empty buffer") ~= nil, "parse: ... and says so specifically")
  end

  do
    local req, err = parse.parse({ "this is not a request line" })
    eq(req, nil, "parse: a first line with no METHOD url shape is rejected")
    ok(err:match("METHOD url") ~= nil, "parse: ... with a message naming the expected shape")
  end

  do
    local req, err = parse.parse({ "GET https://x", "not-a-header-line" })
    eq(req, nil, "parse: a header line with no colon is rejected")
    ok(err:match("header line") ~= nil, "parse: ... with a message naming which line")
  end

  -- Lowercase method: rejected rather than silently uppercased — a typo in
  -- the method is worth surfacing, not guessing past.
  do
    local req, err = parse.parse({ "get https://x" })
    eq(req, nil, "parse: a lowercase method does not match — only %u is accepted")
    ok(err ~= nil, "parse: ... and reports why")
  end
end
