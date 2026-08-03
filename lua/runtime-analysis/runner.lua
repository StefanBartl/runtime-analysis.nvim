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
local json_encode = require("lib.lua.json.encode")

local M = {}

---@param body string
---@return string[]
local function body_lines(body)
  return vim.split(body, "\n", { plain = true })
end

---Whether `headers` name this response's body as JSON — a substring match
---on `Content-Type`'s value (`application/json`, `application/json;
---charset=utf-8`, `application/vnd.api+json`, …) rather than an exact
---match, since real APIs vary the parameters and the `+json` suffix
---convention (RFC 6839) is common enough to be worth catching.
---@param headers table<string, string>
---@return boolean
local function is_json_response(headers)
  for name, value in pairs(headers) do
    if name:lower() == "content-type" and value:lower():find("json", 1, true) then
      return true
    end
  end
  return false
end

---Pretty-print `body` if it decodes as JSON, or `nil` to fall back to the
---raw text verbatim. `vim.json.encode(value, { indent = N })` was tried
---first and rejected: verified against a real call on this Neovim version,
---it does not indent at all — it inserts the literal text of `N` (`"2"`,
---unindented) before each key instead of two spaces. `lib.lua.json.encode`
---is a real, correct, pure-Lua encoder with a genuine `.pretty` mode, which
---is what makes this safe to do automatically now where it was not before.
---
---Both `vim.json.decode` and `encode.pretty` are wrapped defensively: a
---`Content-Type: application/json` header is a claim, not a guarantee — a
---misconfigured server can send that header over a body that is not
---actually valid JSON, and showing the reader the real (if compact)
---response is strictly better than an error where a response used to be.
---@param body string
---@return string[]? pretty_lines
local function try_pretty_json(body)
  local ok_decode, decoded = pcall(vim.json.decode, body)
  if not ok_decode then
    return nil
  end
  local pretty = json_encode.pretty(decoded)
  if not pretty then
    return nil
  end
  return body_lines(pretty)
end

---Run `request` and return response lines ready for `view.lua`, or an error
---string when curl itself failed (unreachable host, timeout) — a different
---failure shape from a real-but-unwelcome HTTP status, which is not an
---error at all: a 404 is a real answer, and is rendered as one.
---@param request { method: string, url: string, headers: table<string, string>, body: string? }
---@return string[]? lines
---@return string? err
---@return { body_start: integer, is_json: boolean }? meta `body_start` is the
---1-based line where the body begins (past the end when there is none);
---`view.lua` uses both for folding/syntax and for "yank just the body".
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

  local body_start = #lines + 1
  local is_json = false

  if resp.body and resp.body ~= "" then
    local pretty_lines
    if is_json_response(resp.headers) then
      pretty_lines = try_pretty_json(resp.body)
      is_json = pretty_lines ~= nil
    end
    vim.list_extend(lines, pretty_lines or body_lines(resp.body))
  end

  return lines, nil, { body_start = body_start, is_json = is_json }
end

return M
