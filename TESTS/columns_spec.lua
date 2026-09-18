-- TESTS/columns_spec.lua — runtime-analysis.ui.columns
--
-- No prior coverage existed for this module at all, despite its own header
-- stating exactly why it exists: aligned tables padded in display cells, not
-- bytes, so a multi-byte character in a cell does not shift a row's tail out
-- of alignment with its neighbours. `M.elide` had exactly that class of bug
-- (below) — the module doing the thing its own doc-comment warns against.

return function(H)
  local eq, ok = H.eq, H.ok
  local columns = require("runtime-analysis.ui.columns")

  -- ljust/rjust: plain ASCII, the common case.
  do
    eq(columns.ljust("abc", 6), "abc   ", "ljust: pads to width with trailing spaces")
    eq(columns.rjust("abc", 6), "   abc", "rjust: pads to width with leading spaces")
    eq(
      columns.ljust("abcdef", 3),
      "abcdef",
      "ljust: already at/over width — unchanged, never cuts"
    )
    eq(columns.rjust("abcdef", 3), "abcdef", "rjust: same — padding never truncates")
  end

  -- ljust/rjust: a multi-byte character that is still *one display cell*
  -- (an accented Latin letter) must pad the same as an ASCII string of the
  -- same display width, not the same *byte* length.
  do
    local s = "café" -- 4 display cells, 5 bytes (é is 2 bytes in UTF-8)
    eq(vim.fn.strdisplaywidth(s), 4, "sanity: café is 4 display cells")
    eq(columns.ljust(s, 6), s .. "  ", "ljust: pads by display width, not byte length")
    eq(columns.rjust(s, 6), "  " .. s, "rjust: same")
  end

  -- elide: a string already within width is returned unchanged.
  do
    eq(columns.elide("short", 10), "short", "elide: no-op when already within width")
  end

  -- elide: plain ASCII over width truncates to width - 1 chars + ellipsis.
  do
    local elided = columns.elide("abcdefghij", 6)
    eq(elided, "abcde…", "elide: ASCII truncates to width-1 chars plus the ellipsis")
    eq(vim.fn.strdisplaywidth(elided), 6, "elide: result is exactly `width` display cells")
  end

  -- BUG (found live, fixed here): `strcharpart(s, 0, width - 1)` truncates
  -- by *character count*, not *display width*. A run of double-width
  -- characters (CJK here) packs two display cells into one `strcharpart`
  -- unit, so counting characters instead of cells let the result blow
  -- straight through the requested budget — before this fix,
  -- `elide("你好世界你好世界", 10)` (16 cells) returned the *entire*
  -- 8-character string plus an ellipsis (17 cells), because 8 characters is
  -- fewer than `width - 1` (9) even though it is far more than `width` (10)
  -- display cells. The whole point of this module — never let a row's tail
  -- drift out of column alignment — failed on exactly the input class its
  -- own header names (CJK/multi-byte paths, namespaces, fingerprints).
  do
    local wide = "你好世界你好世界" -- 8 characters, 16 display cells
    eq(vim.fn.strdisplaywidth(wide), 16, "sanity: 8 CJK characters are 16 display cells")
    local elided = columns.elide(wide, 10)
    ok(
      vim.fn.strdisplaywidth(elided) <= 10,
      "elide: a run of double-width characters is still cut to fit the requested width"
    )
    ok(elided:sub(-3) == "…", "elide: still ends in the ellipsis marker")
  end

  -- elide: a width too small to fit even the ellipsis degrades gracefully
  -- (no error, no result wider than requested) rather than assuming
  -- `width - ellipsis_width` is always positive.
  do
    local elided = columns.elide("abcdefgh", 1)
    eq(vim.fn.strdisplaywidth(elided), 1, "elide: width 1 still respects the budget")
  end

  -- elide: width <= 0 never errors and never returns anything wider than
  -- (empty) — a defensive floor, not a case this plugin's own callers hit
  -- (NAME_W/NUM_W are fixed positive constants), but `strcharpart`/`sub`
  -- with a negative count is exactly the kind of thing that raises instead
  -- of degrading if this guard is ever removed.
  do
    eq(columns.elide("abc", 0), "", "elide: width 0 — empty, not an error")
  end

  -- join_cells: gutter between cells, trailing whitespace dropped so a
  -- right-padded last column does not leave a ragged edge.
  do
    eq(
      columns.join_cells({ "a", "b" }),
      "a" .. columns.GAP .. "b",
      "join_cells: cells joined with the standard gutter"
    )
    eq(
      columns.join_cells({ "a", columns.ljust("b", 5) }),
      "a" .. columns.GAP .. "b",
      "join_cells: trailing whitespace from a right-padded last column is dropped"
    )
  end
end
