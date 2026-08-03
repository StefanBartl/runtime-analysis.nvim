---@module 'runtime-analysis.runner'
--- Executes a parsed request via `lib.nvim.net.curl.fetch_raw_blocking` and
--- formats the result into plain lines for `view.lua` to display.
---
--- Blocking, not async, for this first version: `docs/ECOSYSTEM.md`'s own
--- sequencing (documentation.nvim's, the plugin this one pairs with) calls
--- the in-editor request runner "the cheap first version" specifically
--- because it has no CORS problem, no socket, no token — blocking keeps
--- that same spirit: no request state machine, no "is one already in
--- flight" tracking, just call and wait. A real request against a real API
--- is bounded in the seconds, not minutes; async is a real improvement, not
--- attempted in this first version.

local curl = require("lib.nvim.net.curl")

local M = {}

---The body, split into lines, verbatim — no JSON pretty-printing attempted.
---`vim.json.encode(value, { indent = N })` was tried first and rejected:
---verified against a real call on this Neovim version, it does not indent
---at all — it inserts the literal text of `N` (`"2"`, unindented) before
---each key instead of two spaces, which is worse than showing the original
---compact response. Most real APIs already pretty-print their own
---responses; the ones that do not are still readable compact, and a
---correct pretty-printer is real, separate work, not a small fix to a
---function that turned out not to do what its name suggested.
---@param body string
---@return string[]
local function body_lines(body)
  return vim.split(body, "\n", { plain = true })
end

---Run `request` and return response lines ready for `view.lua`, or an error
---string when curl itself failed (unreachable host, timeout) — a different
---failure shape from a real-but-unwelcome HTTP status, which is not an
---error at all: a 404 is a real answer, and is rendered as one.
---@param request { method: string, url: string, headers: table<string, string>, body: string? }
---@return string[]? lines
---@return string? err
function M.run(request)
  local ok, resp = curl.fetch_raw_blocking(request.url, {
    method = request.method,
    headers = request.headers,
    body = request.body,
  })

  if not ok then
    -- `resp` is the error string in this branch — `fetch_raw_blocking`'s
    -- own contract, the same one `fetch_json_blocking` already has.
    return nil, resp
  end

  local lines = { ("%d %s"):format(resp.status, resp.status_text) }
  local header_names = vim.tbl_keys(resp.headers)
  table.sort(header_names)
  for _, name in ipairs(header_names) do
    lines[#lines + 1] = ("%s: %s"):format(name, resp.headers[name])
  end
  lines[#lines + 1] = ""

  if resp.body and resp.body ~= "" then
    vim.list_extend(lines, body_lines(resp.body))
  end

  return lines
end

return M
