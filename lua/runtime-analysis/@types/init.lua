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

---One recorded send attempt — `runtime-analysis.history`'s own record,
---request-only by design (see that module's doc-comment for why).
---@class RA.History.Entry
---@field method string
---@field url string
---@field status integer? HTTP status, or `nil` when the request errored or was cancelled
---@field note string? Set only when `status` is `nil` — `"cancelled"`, or the transport error text
---@field at integer `os.time()` when this was recorded

---`runtime-analysis.provenance.inspect`.s own result. `source` is `nil` only when `debug.getinfo` itself failed (never
---observed in practice, still not assumed).
---@class RA.Provenance.Info
---@field path string the dotted path as given, e.g. `"vim.notify"`
---@field container_path string everything before the final `.`
---@field container_kind "global"|"module" how `container_path` resolved
---@field field string the final path segment
---@field telemetry { wrapped: boolean, namespaces: string[] } exact — this plugin's own registry
---@field source { what: string, short_src: string, linedefined: integer }? best-effort — where the function currently there was actually defined

---One node in `runtime-analysis.inspect`.s walked tree. A tagged union on `kind`; which other fields are populated depends
---on it and, for `kind == "table"`, on `cyclic`/`truncated`. `key` is
---absent only on the tree's own root.
---@class RA.Inspect.Node
---@field key string?
---@field kind "function"|"table"|"other"
---@field shadows_index boolean present on every node; true when this key also resolves through the parent's `__index` table
---@field nups integer? `kind == "function"` only
---@field source { what: string, short_src: string, linedefined: integer }? `kind == "function"` only
---@field entries RA.Inspect.Node[]? `kind == "table"` only, absent when `cyclic` or `truncated`
---@field has_metatable boolean? `kind == "table"` only
---@field index_kind "table"|"function"|"other"|nil `kind == "table"` only
---@field cyclic true? `kind == "table"` only — this table is its own ancestor
---@field truncated true? `kind == "table"` only — past `max_depth`
---@field field_count integer? `truncated` only — the real field count, even though it was not walked
---@field value_type string? `kind == "other"` only — the real `type()`
---@field value_repr string? `kind == "other"` only — a literal for string/number/boolean, `nil` for anything else

---`runtime-analysis.inspect.inspect`'s own result — the walked tree's
---root, which is itself a table node plus the module id it was walked
---from.
---@class RA.Inspect.Report : RA.Inspect.Node
---@field module_id string

return {}
