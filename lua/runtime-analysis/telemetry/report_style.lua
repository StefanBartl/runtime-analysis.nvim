---@module 'runtime-analysis.telemetry.report_style'
--- Resolve a `report_style` request ("auto" | "kit" | "preview-tab" |
--- "mdview" | "file" | "html") to a concrete destination
--- `:RATelemetry open` can act on.
---
--- Mirrors `lib.nvim.progress.resolve_style`: prefer the richer external
--- integration when it is actually loadable, degrade silently rather than
--- erroring the caller — an external plugin's presence is never
--- stability-guaranteed, and that includes an explicit request for it, not
--- only "auto" (the same choice `progress.resolve_style` makes for an
--- explicit `"fidget"` request).

require("runtime-analysis.telemetry.@types")

local mdview = require("runtime-analysis.telemetry.renderers.mdview")
local preview_tab = require("runtime-analysis.telemetry.renderers.preview_tab")

---@param want RA.Telemetry.ReportStyle|nil
---@return "kit"|"preview-tab"|"mdview"|"file"|"html"
local function resolve(want)
  if want == "kit" then
    return "kit"
  end
  if want == "file" then
    return "file"
  end
  if want == "html" then
    return "html"
  end

  -- **`"preview-tab"` degrades to the float, never sideways to `"mdview"`.**
  -- Both tiers come from the same plugin, so a reader whose mdview is
  -- missing would have "preview-tab" answered with a browser tab and a
  -- binary download — the two things asking for this style says no to. The
  -- float is what an explicit request degrades *to*; `"auto"` below is the
  -- only place a preference gets to shop around.
  if want == "preview-tab" then
    return preview_tab.available() and "preview-tab" or "kit"
  end

  -- "mdview" explicitly, or "auto" (default), or unrecognized: prefer
  -- mdview when it is actually loadable, else the kit float — which is
  -- always available and is what `:RATelemetry` already renders today, so
  -- "nothing regresses when mdview is absent" holds without a special case.
  --
  -- **`"auto"` deliberately still means the browser, not the new in-editor
  -- tier.** The argument for putting `"preview-tab"` first is real — it is
  -- strictly cheaper, and it removes the first-run pause while mdview
  -- fetches its relay. The argument against it decides: `"auto"` is what
  -- every existing configuration already resolves to, and quietly moving
  -- those readers from a browser tab to an editor tab is a changed answer
  -- to a question they settled once. A reader who wants the cheaper tier
  -- says so; nobody has their default rewritten underneath them.
  if mdview.available() then
    return "mdview"
  end
  return "kit"
end

return resolve
