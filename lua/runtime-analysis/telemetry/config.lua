---@module 'runtime-analysis.telemetry.config'
--- Module-level defaults, separate from a per-instance `telemetry.new(opts)`.
---
--- `report_style` has no natural per-instance owner: `:RATelemetry open`
--- with no namespace spans every live instance at once, so there has to be
--- one resolved answer to "how should `open` render", not one per instance.
--- Everything else about telemetry stays instance-scoped on purpose (see
--- `init.lua`'s own doc-comment); this is the one deliberate exception.

local M = {}

require("runtime-analysis.telemetry.@types")

---@type { report_style: RA.Telemetry.ReportStyle }
local G = {
  report_style = "auto",
}

---@param opts? { report_style?: RA.Telemetry.ReportStyle }
function M.setup(opts)
  opts = opts or {}
  if opts.report_style ~= nil then
    G.report_style = opts.report_style
  end
end

---@return RA.Telemetry.ReportStyle
function M.report_style()
  return G.report_style
end

return M
