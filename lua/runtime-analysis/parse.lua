---@module 'runtime-analysis.parse'
--- One HTTP request per buffer *slice*, in the same plain-text shape VS
--- Code's REST Client and IntelliJ's HTTP Client already use — not invented
--- here, picked because it needs no editor chrome to write (a request is
--- just text) and is already a convention a reader coming from either tool
--- recognizes:
---
---   METHOD https://example.com/path?query=1
---   Header-Name: value
---   Another-Header: value
---
---   {"optional": "body", "after": "one blank line"}
---
--- `M.parse` itself has no `###` awareness at all, deliberately: it parses
--- exactly one request out of whatever `lines` it is handed, the same
--- contract it has always had. `###`-separated multi-request buffers
--- (docs/ROADMAP.md §1.2) are `M.split`'s job — it slices a whole buffer
--- into blocks first, and the caller (`bindings/usrcmds.lua`) hands `M.parse`
--- one block's own lines, never the whole buffer, once more than one block
--- exists. A single-block buffer (no `###` line at all) behaves exactly as
--- it always has: one block, the whole buffer.
---
--- One shorthand header exists, `Auth:` — see `resolve_auth_shorthand` below.

local base64 = require("lib.lua.strings.encoding")

local M = {}

---Resolve the `Auth:` header shorthand into a real `Authorization` value.
---
---`Auth: Bearer <token>` passes through verbatim — already the exact wire
---format; the shorthand exists so `Bearer`/`Basic` read as a matched pair
---next to each other, not because Bearer needed shortening.
---
---`Auth: Basic <user>:<pass>` base64-encodes the credentials — the actual
---value-add. RFC 7617 requires the base64 form, and computing it by hand
---(and remembering it is `user:pass`, colon-joined, before encoding) is the
---annoyance this removes.
---
---`Auth: Basic <already-base64>` (no `:` in the value) passes through
---unencoded, on the assumption that base64's own alphabet never contains
---`:`, so a colon reliably signals raw, unencoded credentials and its
---absence reliably signals an already-encoded value pasted in from
---somewhere else.
---
---Anything else after `Auth:` (an unrecognized scheme, or no scheme word at
---all) passes through unchanged as the `Authorization` value — a generic
---fallback rather than an error, so a scheme this function does not know
---about specifically still works, just without the encoding help.
---@param value string
---@return string
local function resolve_auth_shorthand(value)
  local scheme, rest = value:match("^(%a+)%s+(.+)$")
  if scheme and scheme:lower() == "basic" and rest:find(":", 1, true) then
    return "Basic " .. base64.base64_encode(rest)
  end
  return value
end

---Parse one buffer's lines into a request. The first non-blank line must be
---`METHOD URL`; every line after it up to the first blank line is a header
---(`Name: value`); everything after that blank line, verbatim, is the body.
---A request with no blank line at all has no body — headers run to the end
---of the buffer.
---@param lines string[]
---@return { method: string, url: string, headers: table<string, string>, body: string? }? request `nil` when no request line is found.
---@return string? err Set only when `request` is `nil`.
function M.parse(lines)
  local first_idx
  for i, line in ipairs(lines) do
    if vim.trim(line) ~= "" then
      first_idx = i
      break
    end
  end
  if not first_idx then
    return nil, 'empty buffer — expected "METHOD url" on the first non-blank line'
  end

  local method, url = lines[first_idx]:match("^(%u+)%s+(%S+)%s*$")
  if not method then
    return nil,
      ('first line must be "METHOD url" (e.g. "GET https://..."), got: %q'):format(lines[first_idx])
  end

  local headers = {}
  local body_start
  for i = first_idx + 1, #lines do
    local line = lines[i]
    if vim.trim(line) == "" then
      body_start = i + 1
      break
    end
    local name, value = line:match("^([%w%-]+):%s*(.-)%s*$")
    if not name then
      return nil, ("malformed header line %d: %q"):format(i, line)
    end
    if name:lower() == "auth" then
      headers["Authorization"] = resolve_auth_shorthand(value)
    else
      headers[name] = value
    end
  end

  local body
  if body_start and body_start <= #lines then
    body = table.concat(lines, "\n", body_start, #lines)
    -- A body of pure whitespace (trailing blank lines after the real
    -- content) is not a body at all — the same distinction the request
    -- line itself makes for a wholly empty buffer.
    if vim.trim(body) == "" then
      body = nil
    end
  end

  return { method = method, url = url, headers = headers, body = body }
end

---Split `lines` (a whole buffer) into `###`-separated request blocks, the
---same delimiter both VS Code's REST Client and IntelliJ's HTTP Client use.
---A `###` line is a pure separator — excluded from every block, on either
---side of it — so this stays a one-rule splitter with no "is this a name
---comment or a request line" ambiguity to resolve. A buffer with no `###`
---line at all is one block covering the whole buffer, which is why nothing
---upstream of this had to change to keep the single-request case working
---exactly as before.
---@param lines string[]
---@return RA.RequestBlock[]
function M.split(lines)
  local blocks = {}
  local start = 1
  for i, line in ipairs(lines) do
    if line:match("^%s*###") then
      if i > start then
        blocks[#blocks + 1] =
          { first = start, last = i - 1, lines = vim.list_slice(lines, start, i - 1) }
      end
      start = i + 1
    end
  end
  if start <= #lines then
    blocks[#blocks + 1] =
      { first = start, last = #lines, lines = vim.list_slice(lines, start, #lines) }
  end
  return blocks
end

---Which block a 1-based `cursor_line` belongs to: the last block whose
---`first` is at or before the cursor. A cursor sitting exactly on a `###`
---separator line (excluded from every block's own range) resolves to the
---block *above* it by this rule — "still working on the request you were
---just editing, until the cursor actually crosses into the next one's first
---real line" — rather than requiring the cursor to land precisely inside a
---block's own lines. Returns `nil` only for an empty `blocks` list (an
---empty buffer, which `M.parse` on the resulting empty slice would reject
---with its own "empty buffer" error either way).
---@param blocks RA.RequestBlock[]
---@param cursor_line integer 1-based
---@return RA.RequestBlock?
function M.block_at(blocks, cursor_line)
  local best
  for _, block in ipairs(blocks) do
    if cursor_line >= block.first then
      best = block
    end
  end
  return best or blocks[1]
end

return M
