---@module 'runtime-analysis.graphql'
--- GraphQL request support — docs/ROADMAP.md §2.6. VS Code REST Client's
--- own convention, not invented here: a request is marked as GraphQL via
--- an `X-Request-Type: GraphQL` header, and its body is the GraphQL query
--- text, optionally followed by a blank line and a JSON variables object.
--- The header is consumed, never forwarded to the server — the same
--- "shorthand resolves away" pattern `parse.lua`'s own `Auth:` already
--- establishes for `Authorization`.
---
--- What actually goes out on the wire is a plain `POST` with a JSON body
--- shaped `{"query": "...", "variables": {...}}`. This module only ever
--- builds that string; `runner.lua` sends it exactly like any other JSON
--- request, no special casing downstream of `M.resolve`. Cheap to build
--- at all: §2.1 (environments) already exists, so `{{var}}` placeholders
--- inside the query or variables resolve the ordinary way, *before* this
--- module ever runs — `bindings/usrcmds.lua` calls `env.resolve` first,
--- this module second, so a token substituted into the variables text is
--- indistinguishable from one typed there directly.

local M = {}

local HEADER_NAME = "x-request-type"
local HEADER_VALUE = "graphql"

---Whether `headers` mark this request as GraphQL — the `X-Request-Type:
---GraphQL` header, matched case-insensitively on both name and value
---(HTTP header semantics), the same way `parse.lua` already lower-cases
---`Auth:` before comparing it.
---@param headers table<string, string>
---@return boolean
function M.is_graphql(headers)
  for name, value in pairs(headers) do
    if name:lower() == HEADER_NAME and value:lower() == HEADER_VALUE then
      return true
    end
  end
  return false
end

---Split a GraphQL request body into its query and optional variables
---text, on the first blank line — REST Client's own rule ("you need to
---add a blank line between GraphQL query and variables if you need it").
---No blank line at all means no variables block, the whole body is query
---text.
---@param body string
---@return string query
---@return string? variables_text
local function split_body(body)
  local blank_at = body:find("\n[ \t]*\n")
  if not blank_at then
    return vim.trim(body), nil
  end
  local query = vim.trim(body:sub(1, blank_at - 1))
  local rest = vim.trim(body:sub(blank_at))
  return query, rest ~= "" and rest or nil
end

---Transform a GraphQL-shorthand request into the real `POST` it sends:
---strips the `X-Request-Type` header, replaces `body` with
---`{"query": ..., "variables": ...}`. A no-op — returns `request`
---unchanged — when it is not a GraphQL request at all, or has no body to
---build a query from (nothing this module can do with either; `parse.lua`
---or the actual send already reports the more useful "no body" error for
---the latter).
---@param request { method: string, url: string, headers: table<string, string>, body: string? }
---@return { method: string, url: string, headers: table<string, string>, body: string? } request
---@return string? err set only when a GraphQL request's variables text exists but is not valid JSON
function M.resolve(request)
  if not M.is_graphql(request.headers) or not request.body then
    return request, nil
  end

  local query, variables_text = split_body(request.body)
  local variables = vim.empty_dict()
  if variables_text then
    local ok, decoded = pcall(vim.json.decode, variables_text)
    if not ok or type(decoded) ~= "table" then
      return request, "GraphQL variables block is not valid JSON"
    end
    variables = decoded
  end

  local headers = {}
  for name, value in pairs(request.headers) do
    if name:lower() ~= HEADER_NAME then
      headers[name] = value
    end
  end

  return {
    method = request.method,
    url = request.url,
    headers = headers,
    body = vim.json.encode({ query = query, variables = variables }),
  },
    nil
end

return M
