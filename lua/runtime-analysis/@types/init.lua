---@meta
--- Top-level LuaCATS annotations for `runtime-analysis.nvim` itself. Kept
--- separate from `telemetry/@types/init.lua`, the same one-`@types`-folder-
--- per-level convention every sibling plugin uses — telemetry's types
--- describe `RA.Telemetry.*`, this file describes the plugin's own root
--- module, `RA`.

---@class RA
---@field opts { split: string, request_filetype: string }
---@field open_request fun(lines?: string[])
---@field setup fun(opts?: { split?: string, request_filetype?: string, telemetry?: RA.Telemetry.LazyOpts })

---One `###`-separated request block — `runtime-analysis.parse.split`'s own
---output, and what `runtime-analysis.parse.block_at`/`parse` are handed.
---@class RA.RequestBlock
---@field first integer 1-based, inclusive — the block's first line in the original buffer
---@field last integer 1-based, inclusive
---@field lines string[] the block's own lines, ready for `parse.parse`
