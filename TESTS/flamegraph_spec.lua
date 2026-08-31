-- TESTS/flamegraph_spec.lua — the startup require tree, drawn
--
-- Two halves, and the first is the one that matters. `M.tree` rebuilds the
-- require tree from a pre-order sequence plus a depth per entry, because
-- `startup.lua` records no parent pointer and does not need to. That
-- reconstruction is the whole correctness argument of this renderer: get it
-- wrong and every width in the picture is attributed to the wrong module,
-- with nothing on screen looking broken. So it is tested on hand-built
-- sequences with known shapes, not through the SVG.
--
-- The second half checks the SVG only for the properties a reader depends on
-- — every frame present, content escaped, the empty case saying so — and
-- deliberately not for pixel geometry, which is layout taste and would fail
-- on every adjustment to it.

return function(H)
  local eq, ok = H.eq, H.ok
  local flamegraph = require("runtime-analysis.telemetry.renderers.flamegraph")

  ---@param modname string
  ---@param depth integer
  ---@param total number
  ---@param self_ms? number defaults to `total` — a leaf's self time is its whole time
  ---@return table
  local function entry(modname, depth, total, self_ms)
    return { modname = modname, depth = depth, total_ms = total, self_ms = self_ms or total }
  end

  -- ── tree: the empty case ────────────────────────────────────────────────
  eq(#flamegraph.tree({}), 0, "tree: no entries, no roots")
  eq(#flamegraph.tree(nil), 0, "tree: nil is not an error")

  -- ── tree: a flat list is all roots ──────────────────────────────────────
  local flat = flamegraph.tree({
    entry("a", 0, 3),
    entry("b", 0, 2),
    entry("c", 0, 1),
  })
  eq(#flat, 3, "tree: three depth-0 entries are three roots")
  eq(#flat[1].children, 0, "tree: …with no children")

  -- ── tree: nesting, in the shape a real require chain produces ───────────
  --
  --   a            depth 0
  --     b          depth 1
  --       c        depth 2
  --     d          depth 1
  --   e            depth 0
  local nested = flamegraph.tree({
    entry("a", 0, 10),
    entry("b", 1, 6),
    entry("c", 2, 4),
    entry("d", 1, 2),
    entry("e", 0, 5),
  })
  eq(#nested, 2, "tree: two roots")
  eq(nested[1].entry.modname, "a", "tree: …the first is a")
  eq(#nested[1].children, 2, "tree: a has two children")
  eq(nested[1].children[1].entry.modname, "b", "tree: …b")
  eq(nested[1].children[2].entry.modname, "d", "tree: …and d, the sibling after c closed")
  eq(#nested[1].children[1].children, 1, "tree: b has one child")
  eq(nested[1].children[1].children[1].entry.modname, "c", "tree: …c, under b and not under a")
  eq(nested[2].entry.modname, "e", "tree: e is a root again, not a child of a")

  -- ── tree: a depth that jumps attaches, it does not vanish ───────────────
  -- Cannot happen from a real recording; can happen from a truncated or
  -- hand-written list. A wrong parent is recoverable by eye, a silently
  -- missing subtree is not.
  local jumped = flamegraph.tree({
    entry("a", 0, 5),
    entry("deep", 3, 1),
  })
  eq(#jumped, 1, "tree: a depth jump does not create a second root")
  eq(#jumped[1].children, 1, "tree: …the orphan attaches to the deepest ancestor available")
  eq(jumped[1].children[1].entry.modname, "deep", "tree: …and it is still in the tree")

  -- ── svg: the empty report says so, rather than drawing nothing ──────────
  local empty = flamegraph.svg({ order = {}, roots = {}, total_ms = 0 })
  ok(empty:find("<svg", 1, true) ~= nil, "svg: an empty report is still a document")
  ok(empty:find("nothing recorded", 1, true) ~= nil, "svg: …and says why it is empty")
  ok(empty:find("</svg>", 1, true) ~= nil, "svg: …closed")

  -- ── svg: every frame is drawn ───────────────────────────────────────────
  local report = {
    order = {
      entry("alpha", 0, 10, 4),
      entry("alpha.child", 1, 6, 6),
      entry("beta", 0, 5, 5),
    },
    roots = { { root = "alpha", self_ms = 10 }, { root = "beta", self_ms = 5 } },
    total_ms = 15,
  }
  local svg = flamegraph.svg(report)

  local rects = 0
  for _ in svg:gmatch("<rect ") do
    rects = rects + 1
  end
  -- Three frames, one background, two legend swatches.
  eq(rects, 6, "svg: one rect per frame, plus the background and the legend")

  ok(svg:find(">alpha<", 1, true) ~= nil, "svg: a wide frame carries its label")
  ok(svg:find("<title>alpha\n", 1, true) ~= nil, "svg: …and a hover title with the timings")
  ok(svg:find("10.00 ms total, 4.00 ms self", 1, true) ~= nil, "svg: …both numbers, not just one")
  ok(svg:find("beta 5ms", 1, true) ~= nil, "svg: the legend names the heaviest roots")

  -- ── svg: one hue per module root, stable across runs ────────────────────
  -- The property the picture is read by: a plugin's whole subtree is one
  -- colour, so "which block is this" is answered before a label is.
  local fill_alpha = svg:match('rx="2" fill="(#%x%x%x%x%x%x)"')
  ok(fill_alpha ~= nil, "svg: frames are filled with a hex colour")
  eq(
    flamegraph.svg(report):match('rx="2" fill="(#%x%x%x%x%x%x)"'),
    fill_alpha,
    "svg: the same input gives the same colours — a re-render is not a re-theme"
  )
  -- Hex, and never `hsl()`. ImageMagick's librsvg delegate — the path
  -- images.nvim draws this through — does not implement `hsl()` in a fill and
  -- renders it as solid black, which produced a graph of black boxes with
  -- black text. Pinned so it cannot come back as a "nicer" colour computation.
  ok(svg:find("hsl(", 1, true) == nil, "svg: no hsl() anywhere — librsvg renders it black")

  -- ── svg: content is escaped ─────────────────────────────────────────────
  -- A module name cannot contain markup in practice, which is exactly why
  -- this is worth pinning: nobody would notice it breaking.
  local nasty = flamegraph.svg({
    order = { entry("a<b>&c", 0, 1, 1) },
    roots = { { root = "a<b>&c", self_ms = 1 } },
    total_ms = 1,
  })
  ok(nasty:find("&lt;b&gt;", 1, true) ~= nil, "svg: markup in a module name is escaped")
  ok(nasty:find("<b>", 1, true) == nil, "svg: …and does not reach the document raw")

  -- ── svg: a module that raised is marked ─────────────────────────────────
  local raised = flamegraph.svg({
    order = { { modname = "boom", depth = 0, total_ms = 1, self_ms = 1, errored = true } },
    roots = { { root = "boom", self_ms = 1 } },
    total_ms = 1,
  })
  ok(raised:find("raised while loading", 1, true) ~= nil, "svg: a failed load says so in its title")
  ok(
    raised:find('stroke="#b3261e"', 1, true) ~= nil,
    "svg: …and is outlined, visible without hovering"
  )

  -- ── report.order survives sorting and truncation ────────────────────────
  --
  -- The invariant the whole renderer stands on. `modules` is sorted by self
  -- time and cut by `top`; either applied to `order` would silently reorder
  -- or drop subtrees, and the picture would still look plausible.
  local startup = require("runtime-analysis.telemetry.startup")
  startup.reset()

  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  for _, name in ipairs({ "ra_fg_a", "ra_fg_b", "ra_fg_c" }) do
    local f = assert(io.open(dir .. "/" .. name .. ".lua", "w"))
    f:write("return {}")
    f:close()
  end
  local saved_path = package.path
  package.path = dir .. "/?.lua;" .. package.path

  startup.start()
  require("ra_fg_a")
  require("ra_fg_b")
  require("ra_fg_c")
  startup.stop()

  package.path = saved_path
  for _, name in ipairs({ "ra_fg_a", "ra_fg_b", "ra_fg_c" }) do
    package.loaded[name] = nil
  end

  local truncated = startup.report({ top = 1, sort = "name" })
  eq(#truncated.modules, 1, "order: `top` really does cut `modules`")
  ok(#truncated.order >= 3, "order: …and leaves `order` whole")

  local names = {}
  for _, e in ipairs(truncated.order) do
    names[#names + 1] = e.modname
  end
  local joined = table.concat(names, ",")
  local ia = joined:find("ra_fg_a", 1, true)
  local ib = joined:find("ra_fg_b", 1, true)
  local ic = joined:find("ra_fg_c", 1, true)
  ok(ia and ib and ic, "order: every module recorded is in it")
  ok(ia < ib and ib < ic, "order: …in load order, not sorted by name or by time")

  startup.reset()
end
