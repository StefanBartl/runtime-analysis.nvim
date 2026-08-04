-- docs/TESTS/curl_spec.lua — runtime-analysis.curl (docs/ROADMAP.md §2.3)
--
-- Pure logic, no I/O: a pasted curl command line in, a request table (or
-- an error) out — and the reverse, `M.format`.

return function(H)
  local eq, ok = H.eq, H.ok
  local curl = require("runtime-analysis.curl")

  -- Tokenizer: single quotes are literal (bash semantics — nothing inside
  -- is special), double quotes recognize \" and \\ only, an unquoted
  -- backslash escapes exactly the next character, and adjacent
  -- quoted/unquoted segments with no space between them join into one
  -- token.
  do
    local toks = curl._tokenize([['a b' "c\"d" e\ f g'h'i]])
    eq(#toks, 4, "tokenize: four tokens")
    eq(toks[1], "a b", "tokenize: single-quoted content is literal, spaces included")
    eq(toks[2], 'c"d', 'tokenize: \\" inside double quotes is an escaped quote')
    eq(toks[3], "e f", "tokenize: an unquoted backslash escapes the next char (a space)")
    eq(toks[4], "ghi", "tokenize: adjacent unquoted/quoted segments join into one token")
  end

  -- The common case: a browser's real "copy as cURL", multi-line with
  -- bash line continuations.
  do
    local request, err = curl.parse([[
curl 'https://api.example.com/users' \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer abc123' \
  --data-raw '{"name":"Alice"}'
]])
    eq(err, nil, "parse: no error on a real multi-line copy-as-cURL snippet")
    assert(request, "parse: succeeds on a real multi-line copy-as-cURL snippet")
    eq(request.url, "https://api.example.com/users", "parse: url")
    eq(
      request.method,
      "POST",
      "parse: method defaults to POST once --data-raw is present, curl's own default"
    )
    eq(request.headers["Content-Type"], "application/json", "parse: a header")
    eq(request.headers["Authorization"], "Bearer abc123", "parse: another header")
    eq(request.body, '{"name":"Alice"}', "parse: body from --data-raw")
  end

  -- A bare GET, no data at all: method defaults to GET, not POST.
  do
    local request = assert(curl.parse("curl https://example.com/x"))
    eq(request.method, "GET", "parse: no data at all — method defaults to GET")
    eq(request.url, "https://example.com/x", "parse: url with no quoting needed")
    eq(request.body, nil, "parse: no body")
  end

  -- -X explicitly overrides the data-implies-POST default.
  do
    local request = assert(curl.parse("curl -X PUT 'https://x' -d 'a=1'"))
    eq(request.method, "PUT", "parse: explicit -X wins over the data-implies-POST default")
    eq(request.body, "a=1", "parse: body from -d")
  end

  -- Repeated -d/--data segments join with & — real curl's own behavior.
  do
    local request = assert(curl.parse("curl 'https://x' -d 'a=1' -d 'b=2'"))
    eq(request.body, "a=1&b=2", "parse: repeated -d segments join with &")
  end

  -- -u/--user becomes a real Authorization: Basic header, base64-encoded —
  -- the same value-add parse.lua's own Auth: shorthand already provides,
  -- just arriving from a different source.
  do
    local request = assert(curl.parse("curl 'https://x' -u 'alice:s3cret'"))
    local base64 = require("lib.lua.strings.encoding")
    eq(
      request.headers.Authorization,
      "Basic " .. base64.base64_encode("alice:s3cret"),
      "parse: -u becomes a base64-encoded Authorization header"
    )
  end

  -- A flag curl itself understands but this plugin has no use for (-o, a
  -- value-flag) is consumed along with its value, not left to be
  -- misread as the URL.
  do
    local request, err = curl.parse("curl -o out.json 'https://x' -s -L")
    eq(err, nil, "parse: no error with an ignored value-flag and boolean flags present")
    assert(request, "parse: succeeds with -o/-s/-L present")
    eq(request.url, "https://x", "parse: -o's own value never becomes the url")
  end

  -- No URL at all: a real error, not a request with an empty url.
  do
    local request, err = curl.parse("curl -H 'X: 1'")
    eq(request, nil, "parse: nil result when no URL is present at all")
    ok(err ~= nil, "parse: a real error string, not a silent nil-nil")
  end

  -- format: the reverse. GET omits -X; a body uses --data-raw; headers
  -- come out sorted (deterministic output, not insertion-order-dependent).
  do
    local cmd = curl.format({
      method = "GET",
      url = "https://api.example.com/x",
      headers = { B = "2", A = "1" },
    })
    ok(not cmd:find("-X ", 1, true), "format: GET omits -X entirely")
    local a_pos = cmd:find("-H 'A: 1'", 1, true)
    local b_pos = cmd:find("-H 'B: 2'", 1, true)
    ok(a_pos and b_pos and a_pos < b_pos, "format: headers are sorted by name")
  end

  -- format: a value containing a single quote is escaped with the
  -- standard POSIX '\'' trick, not left to break the shell it's pasted
  -- into.
  do
    local cmd = curl.format({
      method = "POST",
      url = "https://x",
      headers = {},
      body = "it's a test",
    })
    ok(
      cmd:find("it'\\''s a test", 1, true) ~= nil,
      "format: embedded single quote is shell-escaped"
    )
  end

  -- Round-trip: parse -> format -> parse again yields the same request —
  -- the honest test that format's own output is itself valid curl syntax
  -- this module's own tokenizer can read back.
  do
    local original = assert(
      curl.parse(
        [[curl 'https://api.example.com/users' -X POST -H 'Content-Type: application/json' -H 'X-Trace: a b' --data-raw '{"n":1}']]
      )
    )
    local roundtripped = assert(curl.parse(curl.format(original)))
    eq(roundtripped.method, original.method, "round-trip: method survives")
    eq(roundtripped.url, original.url, "round-trip: url survives")
    eq(roundtripped.body, original.body, "round-trip: body survives")
    eq(
      roundtripped.headers["Content-Type"],
      original.headers["Content-Type"],
      "round-trip: a header survives"
    )
    eq(
      roundtripped.headers["X-Trace"],
      original.headers["X-Trace"],
      "round-trip: a header with an embedded space survives"
    )
  end
end
