-- TESTS/multipart_spec.lua — runtime-analysis.multipart
-- (docs/ROADMAP.md §2.6)
--
-- Real files on disk for the file-reference cases, not stubs: the whole
-- point of `M.resolve` is reading real bytes, so a fake read would only
-- prove the fake worked.

return function(H)
  local eq, ok = H.eq, H.ok
  local multipart = require("runtime-analysis.multipart")

  local BOUNDARY = "----WebKitFormBoundary7MA4YWxkTrZu0gW"
  local CONTENT_TYPE = "multipart/form-data; boundary=" .. BOUNDARY

  ---@return string
  local function body_with(text_part, file_ref)
    return table.concat({
      "--" .. BOUNDARY,
      'Content-Disposition: form-data; name="text"',
      "",
      text_part,
      "--" .. BOUNDARY,
      'Content-Disposition: form-data; name="image"; filename="1.png"',
      "Content-Type: image/png",
      "",
      "< " .. file_ref,
      "--" .. BOUNDARY .. "--",
    }, "\n")
  end

  -- is_multipart: real Content-Type matching, case-insensitive, a
  -- substring match against the value (real headers carry `boundary=`
  -- after it) rather than an exact one.
  do
    ok(
      multipart.is_multipart({ ["Content-Type"] = CONTENT_TYPE }),
      "is_multipart: a real multipart/form-data header matches"
    )
    ok(
      multipart.is_multipart({ ["content-type"] = "MULTIPART/FORM-DATA; boundary=x" }),
      "is_multipart: case-insensitive on both name and value"
    )
    ok(
      not multipart.is_multipart({ ["Content-Type"] = "application/json" }),
      "is_multipart: an ordinary JSON request is not multipart"
    )
  end

  -- _extract_boundary: quoted and bare forms, real Content-Type shapes.
  do
    eq(
      multipart._extract_boundary("multipart/form-data; boundary=abc123"),
      "abc123",
      "_extract_boundary: bare form"
    )
    eq(
      multipart._extract_boundary('multipart/form-data; boundary="abc 123"'),
      "abc 123",
      "_extract_boundary: quoted form, spaces included"
    )
    eq(
      multipart._extract_boundary("multipart/form-data"),
      nil,
      "_extract_boundary: nil when there is no boundary= at all"
    )
  end

  -- resolve: a real file on disk, read and substituted in place of the
  -- `< path` line -- the boundary structure around it untouched.
  do
    local path = H.tmpfile(".png")
    local f = assert(io.open(path, "wb"))
    f:write("\137PNG\r\n\026\n" .. ("x"):rep(20)) -- real bytes, including a null-free binary-ish prefix
    f:close()

    local dir = vim.fn.fnamemodify(path, ":h")
    local filename = vim.fn.fnamemodify(path, ":t")
    local body = body_with("hello", "./" .. filename)

    local resolved, err = multipart.resolve(body, CONTENT_TYPE, dir)
    eq(err, nil, "resolve: no error when the referenced file really exists")
    assert(resolved, "resolve: succeeds when the referenced file really exists")
    ok(
      resolved:find("hello", 1, true) ~= nil,
      "resolve: the literal text part is carried through unchanged"
    )
    ok(
      resolved:find("\137PNG", 1, true) ~= nil,
      "resolve: the real file bytes replaced the < path line"
    )
    ok(
      resolved:find("< ./", 1, true) == nil,
      "resolve: the < path marker itself is gone, not left alongside the bytes"
    )
    ok(
      resolved:find('Content-Disposition: form-data; name="image"', 1, true) ~= nil,
      "resolve: the surrounding part headers/boundaries are untouched"
    )

    os.remove(path)
  end

  -- resolve: an absolute path (POSIX or a Windows drive letter) is used
  -- as-is, never joined onto base_dir -- the same "already absolute,
  -- don't double it" rule paths get everywhere else in this ecosystem.
  do
    local path = H.tmpfile(".txt")
    local f = assert(io.open(path, "wb"))
    f:write("absolute-file-content")
    f:close()

    local body = body_with("hello", path)
    local resolved = assert(multipart.resolve(body, CONTENT_TYPE, "/some/unrelated/dir"))
    ok(
      resolved:find("absolute%-file%-content") ~= nil,
      "resolve: an absolute path resolves regardless of base_dir"
    )

    os.remove(path)
  end

  -- resolve: a missing file is a real, named error -- not a silently
  -- empty part and not a Lua error propagating out of this module.
  do
    local body = body_with("hello", "./this-file-does-not-exist-at-all.png")
    local resolved, err = multipart.resolve(body, CONTENT_TYPE, vim.fn.getcwd())
    eq(resolved, nil, "resolve: fails when the referenced file does not exist")
    ok(
      err and err:find("this%-file%-does%-not%-exist%-at%-all%.png") ~= nil,
      "resolve: the error names the missing file"
    )
  end

  -- resolve: no boundary= in Content-Type at all -- a real, named error,
  -- not a crash trying to split on an empty delimiter.
  do
    local resolved, err = multipart.resolve("whatever", "multipart/form-data", "/tmp")
    eq(resolved, nil, "resolve: fails with no boundary= in Content-Type")
    ok(err and err:find("boundary", 1, true) ~= nil, "resolve: the error names what is missing")
  end

  -- to_curl_flags: a literal field becomes "name=value"; a file
  -- reference becomes "name=@path;filename=...;type=..." -- paths kept
  -- exactly as written, never resolved against any directory, since an
  -- exported command is meant to run somewhere else entirely.
  do
    local body = body_with("title text", "./1.png")
    local flags, err = multipart.to_curl_flags(body, CONTENT_TYPE)
    eq(err, nil, "to_curl_flags: no error for a real multipart body")
    assert(flags, "to_curl_flags: succeeds for a real multipart body")
    eq(#flags, 2, "to_curl_flags: one flag per real part")
    eq(flags[1], "text=title text", "to_curl_flags: a literal field, verbatim")
    eq(
      flags[2],
      "image=@./1.png;filename=1.png;type=image/png",
      "to_curl_flags: a file reference, path kept exactly as written"
    )
  end

  -- to_curl_flags: no boundary= -- same real, named error as resolve.
  do
    local flags, err = multipart.to_curl_flags("whatever", "multipart/form-data")
    eq(flags, nil, "to_curl_flags: fails with no boundary=")
    ok(err and err:find("boundary", 1, true) ~= nil, "to_curl_flags: names what is missing")
  end

  -- _parse_parts: a part with no Content-Disposition name at all is
  -- still parsed (its headers/content are real), just never turned into
  -- a flag by to_curl_flags -- silently dropping an unnamed part beats
  -- guessing a name for it.
  do
    local body = table.concat({
      "--" .. BOUNDARY,
      "X-Something: whatever", -- no Content-Disposition at all
      "",
      "orphan content",
      "--" .. BOUNDARY .. "--",
    }, "\n")
    local parts = multipart._parse_parts(body, BOUNDARY)
    eq(#parts, 1, "_parse_parts: the part itself is still found")
    eq(parts[1].content_lines[1], "orphan content", "_parse_parts: its content is real")

    local flags = assert(multipart.to_curl_flags(body, CONTENT_TYPE))
    eq(#flags, 0, "to_curl_flags: a nameless part contributes no flag, not a guessed one")
  end
end
