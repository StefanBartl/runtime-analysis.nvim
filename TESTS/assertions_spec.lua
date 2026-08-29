-- TESTS/assertions_spec.lua — runtime-analysis.assertions
--
-- Pure logic, no I/O: a request block's own lines in, the `@expect status
-- N` directive (or an error) out, plus the stripped lines `parse.parse`
-- actually sees.

return function(H)
  local eq, ok = H.eq, H.ok
  local assertions = require("runtime-analysis.assertions")

  -- No directive at all: nil, no error — the common case, an ordinary
  -- request buffer with no assertion at all.
  do
    local found, err = assertions.extract({ "GET https://x", "" })
    eq(found, nil, "extract: no directive at all — nil, not an error")
    eq(err, nil, "extract: ... and no error either")
  end

  -- `#` directive, before the request line — the documented shape.
  do
    local found = assert(assertions.extract({ "# @expect status 200", "GET https://x" }))
    eq(found.status, 200, "extract: status parsed as a number")
    eq(found.line, 1, "extract: line is 1-based, relative to the given lines")
  end

  -- `//` directive too — IntelliJ HTTP Client's own comment style, not
  -- only VS Code REST Client's `#`.
  do
    local found = assert(assertions.extract({ "// @expect status 404" }))
    eq(found.status, 404, "extract: status parsed correctly for //")
  end

  -- Anywhere in the block, not only the first line — after headers, say.
  do
    local found =
      assert(assertions.extract({ "GET https://x", "Accept: */*", "# @expect status 200", "" }))
    eq(found.line, 3, "extract: line reflects its real position")
  end

  -- Two directives: a real, named error — not "last one wins" silently.
  do
    local found, err =
      assertions.extract({ "# @expect status 200", "GET https://x", "# @expect status 404" })
    eq(found, nil, "extract: nil result when more than one directive is present")
    ok(
      err and err:find("1", 1, true) and err:find("3", 1, true),
      "extract: error names both line numbers"
    )
  end

  -- A line that merely mentions "@expect" without the exact shape is not
  -- a directive at all — no partial/fuzzy matching.
  do
    local found = assertions.extract({ "# just a comment about @expect status maybe" })
    eq(found, nil, "extract: a line only resembling the directive is not matched")
  end

  -- strip removes exactly the directive line(s), nothing else, and
  -- preserves the order of everything that remains.
  do
    local lines = { "# @expect status 200", "GET https://x", "Accept: */*", "" }
    local stripped = assertions.strip(lines)
    eq(#stripped, 3, "strip: removes exactly the one directive line")
    eq(stripped[1], "GET https://x", "strip: the request line survives, now first")
    eq(stripped[2], "Accept: */*", "strip: a header survives untouched")
    eq(stripped[3], "", "strip: the trailing blank line survives")
  end

  -- strip on a block with no directive at all is a no-op (equal content,
  -- not necessarily the same table).
  do
    local lines = { "GET https://x", "" }
    local stripped = assertions.strip(lines)
    eq(#stripped, 2, "strip: no directive present — nothing removed")
    eq(stripped[1], "GET https://x", "strip: content unchanged")
  end
end
