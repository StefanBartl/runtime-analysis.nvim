---@module 'runtime-analysis.telemetry.report_file'
--- Where a rendered Markdown report lives on disk, and writing one there.
---
--- A separate artifact from the JSON counters `store.lua` persists — this is
--- what `report_file = true` (periodic, at every flush) and `:RATelemetry
--- open` (on demand) both write, and what `renderers/mdview.lua` hands to
--- `:MDView standalone` to watch. Deliberately its own file: the JSON store
--- answers "what happened", this answers "where does the human-readable
--- version of that live" — different question, different lifetime (this one
--- is disposable; delete it and the next flush or `open` rebuilds it).

local store = require("runtime-analysis.telemetry.store")

local M = {}

---@param opts? Lib.Cache.Opts
---@return string
function M.dir(opts)
  local root = (opts and opts.dir) or (vim.fn.stdpath("cache") .. "/runtime-analysis.nvim")
  return root .. "/telemetry"
end

---@param namespace string
---@param opts? Lib.Cache.Opts
---@return string
function M.namespace_path(namespace, opts)
  return M.dir(opts) .. "/" .. store.sanitize(namespace) .. ".md"
end

---The HTML dashboard's own path — a sibling of
---`M.namespace_path`, `.html` rather than `.md`, same directory. A
---separate extension rather than a separate directory: both are
---disposable per-namespace snapshots of the same underlying report, not
---two different kinds of data.
---@param namespace string
---@param opts? Lib.Cache.Opts
---@return string
function M.namespace_html_path(namespace, opts)
  return M.dir(opts) .. "/" .. store.sanitize(namespace) .. ".html"
end

---The combined, all-instances document `:RATelemetry open` (no namespace)
---renders — a snapshot at invocation time, not self-updating like a
---per-namespace file can be. See the "Browser report" section of this
---module's README.md for why only the per-namespace path can be a live
---`:MDView standalone` target.
---@param opts? Lib.Cache.Opts
---@return string
function M.combined_path(opts)
  return M.dir(opts) .. "/report.md"
end

---The combined HTML dashboard's own path — see `M.namespace_html_path`.
---@param opts? Lib.Cache.Opts
---@return string
function M.combined_html_path(opts)
  return M.dir(opts) .. "/report.html"
end

---The startup flamegraph's own path. Not per-namespace, and that is the
---whole difference: startup attribution measures module loads, not one
---namespace's wrapped functions, so there is exactly one of these per
---session. Same directory and same disposability as the reports beside it.
---@param opts? Lib.Cache.Opts
---@return string
function M.flamegraph_path(opts)
  return M.dir(opts) .. "/startup-flamegraph.svg"
end

---Best-effort: never raises. A report file is a convenience artifact, not
---data — a write failure (a locked file, a full disk) must not take down
---the flush that triggered it.
---@param path string
---@param lines string[]
---@return boolean ok, string|nil err
function M.write(path, lines)
  local ok, err = require("lib.nvim.fs.write.to_file")(path, table.concat(lines, "\n"))
  if not ok then
    return false, tostring(err)
  end
  return true, nil
end

return M
