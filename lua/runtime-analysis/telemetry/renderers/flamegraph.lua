---@module 'runtime-analysis.telemetry.renderers.flamegraph'
--- The startup require tree as a flamegraph, drawn as a standalone SVG.
---
--- **The data was already here; only the picture was missing.**
--- `telemetry/startup.lua` wraps the global `require` and times every cache
--- miss against a stack, so each entry carries `depth`, `total_ms` and a
--- `self_ms` that has its children subtracted out. That is precisely a
--- flamegraph: width is time, depth is nesting, and a parent's uncovered
--- strip is its own work. `lines()` and `markdown()` already render that data
--- as text; this is the third renderer over the same report, in the shape the
--- question actually has — "what did startup spend its time inside" is a
--- nesting question, and a sorted table flattens the one dimension that
--- answers it.
---
--- **Why SVG and not a raster image.** It is text, so it diffs, it costs no
--- image library to produce, and it stays sharp at any zoom — which matters
--- here, because the interesting frames are the narrow ones. `images.nvim`
--- turns it into a PNG through its existing cached SVG conversion when it
--- has to be drawn in a terminal, so choosing SVG here costs nothing there.
---
--- **Why the tree can be rebuilt at all.** `startup.lua` records no parent
--- pointer — only a depth. It does not need one: entries are appended when a
--- load *begins*, which makes the list a pre-order traversal, and a pre-order
--- sequence plus a depth per node determines the tree uniquely. `M.tree`
--- does that with a stack indexed by depth, which is the same stack the
--- recorder used, reconstructed after the fact.
---
--- Deliberately **not** fed from `report.modules`: that list is sorted by
--- self time and may be truncated by `top`, and either of those turns a
--- flamegraph into a lie about widths. `report.order` is the untouched
--- sequence, and it exists for this.

local esc = require("lib.lua.strings.encoding").html_escape

local M = {}

--- Geometry. Everything else scales off these.
local ROW_H = 18
local WIDTH = 1200
local PAD = 12
local HEADER_H = 46
local LEGEND_H = 20
local FONT = "ui-monospace,SFMono-Regular,Menlo,Consolas,monospace"

--- Below this many pixels a frame gets no label — three characters and an
--- ellipsis need roughly this much, and text narrower than its box is worse
--- than no text because it overflows into the neighbour.
local MIN_LABEL_PX = 26

--- Light background, dark ink, warm frames: the look every flamegraph has
--- had since the format existed, and the one that survives being pasted into
--- a ticket or converted to a PNG. A dark variant was considered and dropped
--- — this artifact's job is to leave the editor, and a transparent or dark
--- card is the wrong default for everywhere it lands.
local INK = "#1a1a19"
local MUTED = "#6b6b68"
local BG = "#fbfbfa"

---@param modname string
---@return string
local function root_of(modname)
  return (modname:match("^([^.]+)") or modname)
end

--- The frame palette: fixed hex, not computed `hsl()`.
---
--- `hsl()` was the first attempt and it is the obvious one — a hue from a
--- hash, fixed saturation and lightness, every root its own colour. It
--- renders correctly in a browser and comes out **solid black** through
--- ImageMagick's librsvg delegate, which does not implement CSS `hsl()` in a
--- `fill` and falls back to the initial value. That delegate is not an
--- afterthought here: it is the path `images.nvim` uses to draw this file in
--- a terminal, so the primary consumer would have received a graph of black
--- boxes with black text on them. Found by rasterizing and looking at the
--- result, which is the only way this class of bug is ever found.
---
--- Twelve entries, all light enough for `INK` text to stay readable, all far
--- enough apart to be told from a neighbour at 18 pixels tall.
---@type string[]
local PALETTE = {
  "#f2c9a0",
  "#e8b7b7",
  "#d9c2e0",
  "#b9cde8",
  "#a8d6cf",
  "#bcd9a8",
  "#e6d9a0",
  "#d8b89a",
  "#c9bfe0",
  "#a8c4d9",
  "#b0d8c0",
  "#dcc9b0",
}

--- A stable colour per module root, so one plugin keeps one colour across
--- the whole graph and across runs.
---
--- Hashing the *root* rather than the full module name is the point: a
--- flamegraph whose every frame is a different colour shows nothing, while
--- one where a plugin's whole subtree shares a colour answers "who is this
--- block" before a single label is read.
---@param modname string
---@return string
local function colour_of(modname)
  local root = root_of(modname)
  local h = 5381
  for i = 1, #root do
    h = (h * 33 + root:byte(i)) % 4294967296
  end
  return PALETTE[(h % #PALETTE) + 1]
end

---@class RA.Telemetry.Flamegraph.Node
---@field entry RA.Telemetry.Startup.Entry
---@field children RA.Telemetry.Flamegraph.Node[]

--- Rebuild the require tree from a pre-order sequence plus per-entry depth.
---
--- A node at depth `d` is a child of the most recent preceding node at depth
--- `d - 1`; the stack holds exactly that, one slot per level. Entries whose
--- depth jumps by more than one (which cannot happen from a real recording,
--- but can from a hand-written or truncated list) attach to the deepest
--- available ancestor rather than being dropped — a wrong parent is
--- recoverable by eye, a silently missing subtree is not.
---@param order RA.Telemetry.Startup.Entry[]|nil  load order, untouched
---@return RA.Telemetry.Flamegraph.Node[] roots
function M.tree(order)
  local roots, stack = {}, {}
  for _, entry in ipairs(order or {}) do
    local node = { entry = entry, children = {} }
    local depth = entry.depth or 0
    while #stack > depth do
      stack[#stack] = nil
    end
    local parent = stack[#stack]
    if parent then
      parent.children[#parent.children + 1] = node
    else
      roots[#roots + 1] = node
    end
    stack[#stack + 1] = node
  end
  return roots
end

--- The deepest nesting level in a forest, 1-based (an empty forest is 0).
---@param nodes RA.Telemetry.Flamegraph.Node[]
---@return integer
local function depth_of(nodes)
  local deepest = 0
  for _, node in ipairs(nodes) do
    local below = depth_of(node.children)
    if below + 1 > deepest then
      deepest = below + 1
    end
  end
  return deepest
end

---@param nodes RA.Telemetry.Flamegraph.Node[]
---@return number
local function span_of(nodes)
  local total = 0
  for _, node in ipairs(nodes) do
    total = total + (node.entry.total_ms or 0)
  end
  return total
end

---@param s string
---@param width_px number
---@return string
local function fit_label(s, width_px)
  -- 6.2px per character at font-size 11 in a monospace face, measured rather
  -- than guessed: a narrower estimate leaves visible gaps, a wider one lets
  -- the last glyph cross the frame edge.
  local room = math.floor((width_px - 6) / 6.2)
  if room <= 0 then
    return ""
  end
  if #s <= room then
    return s
  end
  if room <= 1 then
    return ""
  end
  return s:sub(1, room - 1) .. "\u{2026}"
end

---@param out string[]
---@param node RA.Telemetry.Flamegraph.Node
---@param x number
---@param y number
---@param scale number  pixels per millisecond
local function draw(out, node, x, y, scale)
  local entry = node.entry
  local total = entry.total_ms or 0
  local w = total * scale
  -- Frames thinner than a pixel are still drawn. Dropping them is the
  -- conventional optimisation and it is wrong here: a startup tree has
  -- hundreds of modules, not millions, so the whole graph stays a few
  -- hundred rectangles either way — and a dropped frame is exactly the
  -- cheap module somebody is looking for when they ask why the total is
  -- larger than the parts they can see.
  if w <= 0 then
    w = 0.4
  end

  local label = fit_label(entry.modname, w)
  out[#out + 1] = ("<g><title>%s\n%.2f ms total, %.2f ms self%s</title>"):format(
    esc(entry.modname),
    total,
    entry.self_ms or 0,
    entry.errored and "\nraised while loading" or ""
  )
  out[#out + 1] = ('<rect x="%.2f" y="%d" width="%.2f" height="%d" rx="2" fill="%s" stroke="%s" stroke-width="0.5"/>'):format(
    x,
    y,
    w,
    ROW_H - 1,
    colour_of(entry.modname),
    entry.errored and "#b3261e" or "rgba(0,0,0,.18)"
  )
  if label ~= "" and w >= MIN_LABEL_PX then
    out[#out + 1] = ('<text x="%.2f" y="%d" font-size="11" fill="%s">%s</text>'):format(
      x + 3,
      y + ROW_H - 6,
      INK,
      esc(label)
    )
  end
  out[#out + 1] = "</g>"

  -- Children sit on the next row, laid out left to right inside this frame.
  -- Whatever width is left over at the end is this module's own work — the
  -- uncovered strip that makes a flamegraph readable at a glance.
  local cx = x
  for _, child in ipairs(node.children) do
    draw(out, child, cx, y + ROW_H, scale)
    cx = cx + math.max((child.entry.total_ms or 0) * scale, 0.4)
  end
end

--- Render a startup report as a standalone SVG document.
---@param report RA.Telemetry.Startup.Drawable
---@param opts? { width?: integer, title?: string }
---@return string svg
function M.svg(report, opts)
  opts = opts or {}
  local width = opts.width or WIDTH
  local title = opts.title or "startup attribution"

  local roots = M.tree(report and report.order or {})
  local span = span_of(roots)
  local rows = depth_of(roots)

  local plot_w = width - PAD * 2
  local height = HEADER_H + rows * ROW_H + LEGEND_H + PAD

  local out = {}
  -- The XML declaration is not decoration. Without it a rasterizer is free to
  -- read the file in whatever encoding its locale suggests, and this document
  -- carries multi-byte characters (a middle dot in the header, an ellipsis on
  -- every truncated label). Measured, not assumed: ImageMagick's SVG delegate
  -- warned `Invalid UTF-8 string passed to pango_layout_set_text()` on a file
  -- that was in fact valid UTF-8, and the declaration silenced it.
  out[#out + 1] = [[<?xml version="1.0" encoding="UTF-8"?>]]
  out[#out + 1] = ([[<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d" font-family="%s">]]):format(
    width,
    height,
    width,
    height,
    FONT
  )
  -- An explicit background rather than a transparent one: this file is meant
  -- to leave the editor, and every consumer that converts it (images.nvim's
  -- cached SVG->PNG among them) renders transparency as whatever sits behind
  -- it, which for a terminal is usually black under dark text.
  out[#out + 1] = ('<rect width="100%%" height="100%%" fill="%s"/>'):format(BG)

  out[#out + 1] = ('<text x="%d" y="20" font-size="13" fill="%s">%s</text>'):format(
    PAD,
    INK,
    esc(title)
  )
  out[#out + 1] = ('<text x="%d" y="36" font-size="11" fill="%s">%s</text>'):format(
    PAD,
    MUTED,
    esc(
      ("%d module(s) · %.1f ms · width is total time, depth is require nesting"):format(
        #(report and report.order or {}),
        span
      )
    )
  )

  if #roots == 0 then
    out[#out + 1] = ('<text x="%d" y="%d" font-size="11" fill="%s">%s</text>'):format(
      PAD,
      HEADER_H + 12,
      MUTED,
      "nothing recorded — start() must run before the modules you want to see"
    )
    out[#out + 1] = "</svg>"
    return table.concat(out, "\n")
  end

  local scale = span > 0 and (plot_w / span) or 0
  local x = PAD
  for _, node in ipairs(roots) do
    draw(out, node, x, HEADER_H, scale)
    x = x + math.max((node.entry.total_ms or 0) * scale, 0.4)
  end

  -- A legend of the heaviest roots, in the same colours the frames use. Five
  -- entries, because the point is "which blocks am I looking at", not a
  -- second copy of the by-plugin table `lines()` already prints in full.
  local legend_y = HEADER_H + rows * ROW_H + 14
  local lx = PAD
  for i, root in ipairs(report.roots or {}) do
    if i > 5 then
      break
    end
    out[#out + 1] = ('<rect x="%d" y="%d" width="9" height="9" rx="2" fill="%s"/>'):format(
      lx,
      legend_y - 8,
      colour_of(root.root)
    )
    local label = ("%s %.0fms"):format(root.root, root.self_ms)
    out[#out + 1] = ('<text x="%d" y="%d" font-size="10" fill="%s">%s</text>'):format(
      lx + 13,
      legend_y,
      MUTED,
      esc(label)
    )
    lx = lx + 13 + #label * 6 + 14
  end

  out[#out + 1] = "</svg>"
  return table.concat(out, "\n")
end

return M
