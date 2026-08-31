-- Test code: when something here comes back nil -- a `pcall(require, ...)`,
-- a fixture read, a uv handle -- this file must crash and name it. The nil
-- guards LuaLS asks for below would hide the very failure it exists to report.
---@diagnostic disable: need-check-nil
-- TESTS/parse_spec.lua — runtime-analysis.parse
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

  -- The `Auth:` shorthand.
  do
    local req = parse.parse({ "GET https://x", "Auth: Bearer abc123" })
    eq(
      req.headers["Authorization"],
      "Bearer abc123",
      "parse: Auth: Bearer passes through verbatim as Authorization"
    )
    eq(req.headers["Auth"], nil, "parse: ... and Auth itself is not left as a header")
  end

  do
    local req = parse.parse({ "GET https://x", "Auth: Basic alice:s3cret" })
    eq(
      req.headers["Authorization"],
      "Basic " .. require("lib.lua.strings.encoding").base64_encode("alice:s3cret"),
      "parse: Auth: Basic user:pass is base64-encoded into Authorization"
    )
  end

  do
    -- No colon in the value: assumed already base64-encoded, passed through.
    local req = parse.parse({ "GET https://x", "Auth: Basic YWxpY2U6czNjcmV0" })
    eq(
      req.headers["Authorization"],
      "Basic YWxpY2U6czNjcmV0",
      "parse: Auth: Basic with no colon passes through unencoded"
    )
  end

  do
    -- An unrecognized scheme: passed through as the Authorization value,
    -- not rejected — a generic fallback, not an error.
    local req = parse.parse({ "GET https://x", "Auth: Digest username=alice" })
    eq(
      req.headers["Authorization"],
      "Digest username=alice",
      "parse: an unrecognized Auth scheme still passes through, unmodified"
    )
  end

  do
    -- A literal Authorization header still works exactly as before —
    -- the shorthand only intercepts the Auth: name, not Authorization:.
    local req = parse.parse({ "GET https://x", "Authorization: Bearer already-full" })
    eq(
      req.headers["Authorization"],
      "Bearer already-full",
      "parse: a literal Authorization header is untouched by the shorthand"
    )
  end

  -- `###`-separated multi-request buffers.
  do
    -- No `###` at all: one block, the whole buffer — unchanged behavior
    -- from before this existed.
    local lines = { "GET https://a", "", "body a" }
    local blocks = parse.split(lines)
    eq(#blocks, 1, "split: no ### at all is one block")
    eq(blocks[1].first, 1, "split: ... covering line 1")
    eq(blocks[1].last, 3, "split: ... through the last line")
    eq(
      table.concat(blocks[1].lines, "|"),
      table.concat(lines, "|"),
      "split: ... the whole buffer verbatim"
    )
  end

  do
    -- Two requests, ### between them.
    local lines =
      { "GET https://a", "", "### ", "POST https://b", "Content-Type: text/plain", "", "body b" }
    local blocks = parse.split(lines)
    eq(#blocks, 2, "split: two ###-separated blocks")
    eq(blocks[1].first, 1, "split: block 1 starts at line 1")
    eq(blocks[1].last, 2, "split: block 1 ends right before the ### line")
    eq(table.concat(blocks[1].lines, "|"), "GET https://a|", "split: block 1's own lines")
    eq(blocks[2].first, 4, "split: block 2 starts right after the ### line")
    eq(blocks[2].last, 7, "split: block 2 runs to the end")

    local req1 = parse.parse(blocks[1].lines)
    eq(req1.method, "GET", "split: block 1 parses as its own request")
    local req2 = parse.parse(blocks[2].lines)
    eq(req2.method, "POST", "split: block 2 parses as a separate request")
    eq(req2.body, "body b", "split: block 2's body is its own, not block 1's")
  end

  do
    -- A leading ### before the very first request: still excluded from
    -- the block that follows it, the same rule every separator gets.
    local lines = { "###", "GET https://a" }
    local blocks = parse.split(lines)
    eq(#blocks, 1, "split: a leading ### produces one block, not an empty one plus a real one")
    eq(blocks[1].lines[1], "GET https://a", "split: ... and the ### itself is excluded from it")
  end

  do
    -- block_at: cursor inside each block resolves to that block.
    local lines = { "GET https://a", "", "###", "POST https://b", "", "body" }
    local blocks = parse.split(lines)
    eq(parse.block_at(blocks, 1).first, 1, "block_at: cursor on block 1's first line")
    eq(parse.block_at(blocks, 2).first, 1, "block_at: cursor anywhere else inside block 1")
    eq(parse.block_at(blocks, 4).first, 4, "block_at: cursor inside block 2")
    eq(parse.block_at(blocks, 6).first, 4, "block_at: cursor on block 2's last line")
  end

  do
    -- block_at: cursor exactly on a ### separator resolves to the block
    -- above it, not the one below — "still the request you were editing".
    local lines = { "GET https://a", "###", "POST https://b" }
    local blocks = parse.split(lines)
    eq(
      parse.block_at(blocks, 2).first,
      1,
      "block_at: cursor on the ### line itself favors the block above it"
    )
  end

  -- `.rest` ftdetect. `*.http` already resolves to
  -- filetype `http` in stock Neovim with no plugin at all — verified
  -- separately, not re-asserted here, since nothing in this repo could
  -- meaningfully break that. `ftdetect/runtime-analysis.lua` is a plain
  -- script, not a `require`-able module (Neovim's own convention for the
  -- whole `ftdetect/` directory), so it is `dofile`d directly rather than
  -- `require`d.
  do
    local dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
    -- One level up, not two: this suite sits at the repository root
    -- (`TESTS/`), not under `docs/`, where it used to.
    dofile(dir .. "../ftdetect/runtime-analysis.lua")
    eq(
      vim.filetype.match({ filename = "requests.rest" }),
      "http",
      "ftdetect: *.rest resolves to filetype http"
    )
  end
end
