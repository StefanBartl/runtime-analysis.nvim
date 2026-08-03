---@module 'runtime-analysis.parse'
--- One HTTP request per buffer, in the same plain-text shape VS Code's REST
--- Client and IntelliJ's HTTP Client already use — not invented here, picked
--- because it needs no editor chrome to write (a request is just text) and
--- is already a convention a reader coming from either tool recognizes:
---
---   METHOD https://example.com/path?query=1
---   Header-Name: value
---   Another-Header: value
---
---   {"optional": "body", "after": "one blank line"}
---
--- Deliberately one request per buffer for this first version — chaining
--- multiple `###`-separated requests in one file (both tools above support
--- it) is real and not attempted yet; see the plugin's own README for why.

local M = {}

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
    headers[name] = value
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

return M
