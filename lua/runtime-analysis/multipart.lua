---@module 'runtime-analysis.multipart'
--- Multipart/form-data support — VS Code REST
--- Client's own convention, not invented here: a boundary-delimited body
--- (`Content-Type: multipart/form-data; boundary=...`), one
--- `Content-Disposition: form-data; name="..."` part per field, and a
--- part whose content is a bare `< ./relative/path` line means "read this
--- local file's bytes as the part body" — the same `< file` convention
--- curl's own `-d` flag already uses for "read from a file", not invented
--- here either.
---
--- Two different jobs need two different outputs from the same parsed
--- parts, and this module keeps them separate rather than picking one:
---
---   * **Sending** (`M.resolve`) needs the real bytes, right now, to hand
---     `lib.nvim.net.curl.fetch_raw` a literal body string — Lua strings
---     are byte arrays, so a binary file's content is exactly as safe to
---     carry here as text.
---   * **Exporting** (`M.to_curl_flags`) must *not* inline those bytes —
---     a shared `curl` command is shell text, and a binary file's raw
---     bytes are not safe shell-embeddable text (a stray `'`, a null
---     byte, anything). curl's own `-F "field=@path"` already solves
---     this exactly: it reads the file itself when the command actually
---     runs, so export only ever has to name the field and the path, kept
---     relative and as-written — a shared command is portable precisely
---     because it does *not* bake in the machine-specific absolute path
---     that resolved it here.
---
--- Line endings are the one honest gap: this only ever joins with `\n`,
--- matching the request buffer's own line ending, not RFC 2046's
--- required CRLF. Every server encountered while building this accepts
--- bare `\n` in practice — real multipart parsers are lenient about it —
--- but a hypothetical strict one is not handled.

local M = {}

---Whether `headers` name a multipart/form-data body.
---@param headers table<string, string>
---@return boolean
function M.is_multipart(headers)
  for name, value in pairs(headers) do
    if name:lower() == "content-type" and value:lower():find("multipart/form-data", 1, true) then
      return true
    end
  end
  return false
end

---`boundary=...` out of a `Content-Type` header value — quoted or bare,
---curl and every real client accept both.
---@internal
---@param content_type string
---@return string? boundary
local function extract_boundary(content_type)
  return content_type:match('boundary="([^"]+)"') or content_type:match("boundary=([^;%s]+)")
end
M._extract_boundary = extract_boundary -- test-only

---@class RA.Multipart.Part
---@field headers table<string, string> lower-cased header names, e.g. `content-disposition`, `content-type`
---@field content_lines string[] the part's own body lines, verbatim — a single `< ./path` line for a file reference, one or more literal lines otherwise

---Split a multipart body into its parts, delimited by `--boundary` /
---`--boundary--` lines. Deliberately tolerant of what comes before the
---first delimiter and after the last: a body pasted with leading/trailing
---blank lines still parses the same real parts.
---@internal
---@param body string
---@param boundary string
---@return RA.Multipart.Part[]
local function parse_parts(body, boundary)
  local delimiter = "--" .. boundary
  local lines = vim.split(body, "\n", { plain = true })
  local parts = {}
  ---@type RA.Multipart.Part?
  local current = nil
  local in_headers = true

  for _, raw_line in ipairs(lines) do
    local line = raw_line:gsub("\r$", "")
    if line == delimiter or line == delimiter .. "--" then
      if current then
        parts[#parts + 1] = current
      end
      current = (line == delimiter) and { headers = {}, content_lines = {} } or nil
      in_headers = true
    elseif current then
      if in_headers then
        if line == "" then
          in_headers = false
        else
          local name, value = line:match("^([%w%-]+):%s*(.-)%s*$")
          if name then
            current.headers[name:lower()] = value
          end
        end
      else
        current.content_lines[#current.content_lines + 1] = raw_line
      end
    end
  end

  return parts
end
M._parse_parts = parse_parts -- test-only

---A part's field `name` and optional `filename`, out of its
---`Content-Disposition: form-data; name="..."; filename="..."` header.
---@internal
---@param part RA.Multipart.Part
---@return string? name
---@return string? filename
local function part_identity(part)
  local disp = part.headers["content-disposition"]
  if not disp then
    return nil, nil
  end
  return disp:match('name="([^"]*)"'), disp:match('filename="([^"]*)"')
end

---A part's own content, as a single string, and whether it is a `< path`
---file reference rather than literal text — a file reference is
---recognized only when it is the part's *entire* content (one line,
---nothing else), the same way `parse.lua` elsewhere never guesses at a
---shape that could mean two different things.
---@internal
---@param part RA.Multipart.Part
---@return string content
---@return string? file_ref the path after `< `, when the content is exactly one such line
local function part_content(part)
  local content = table.concat(part.content_lines, "\n")
  if #part.content_lines == 1 then
    local ref = part.content_lines[1]:match("^<%s+(.+)$")
    if ref then
      return content, ref
    end
  end
  return content, nil
end

---Resolve every `< ./path` file reference in a multipart body to that
---file's real bytes, read relative to `base_dir` — the request buffer's
---own directory when it has one, the cwd otherwise (see
---`bindings/usrcmds.lua`'s own call site for which). The boundary
---structure itself (the `Content-Type`'s `boundary=`, the delimiter
---lines) is left exactly as written; only a file-reference *line* is
---ever replaced, never the surrounding headers.
---@param body string
---@param content_type string the request's own `Content-Type` header value, for `boundary=`
---@param base_dir string
---@return string? resolved
---@return string? err set when `boundary=` is missing, or a referenced file could not be read
function M.resolve(body, content_type, base_dir)
  local boundary = extract_boundary(content_type)
  if not boundary then
    return nil, "multipart/form-data with no boundary= in Content-Type"
  end

  local lines = vim.split(body, "\n", { plain = true })
  local out = {}
  for _, line in ipairs(lines) do
    local rel = line:match("^<%s+(.+)$")
    if rel then
      local path = (rel:match("^/") or rel:match("^%a:[\\/]")) and rel or (base_dir .. "/" .. rel)
      local f, open_err = io.open(path, "rb")
      if not f then
        return nil, ("could not read %s: %s"):format(rel, open_err or "unknown error")
      end
      local content = f:read("*a")
      f:close()
      out[#out + 1] = content
    else
      out[#out + 1] = line
    end
  end

  return table.concat(out, "\n"), nil
end

---The reverse direction, for `:RA export`: one `-F` argument value per
---part, ready for `curl.lua`'s own `shq`-quoting — `"name=value"` for a
---literal field, `"name=@path;filename=...;type=..."` for a file
---reference. Paths are kept exactly as written, never resolved against a
---base directory: an exported command is meant to run somewhere else
---entirely, and baking in this machine's own absolute path would make it
---portable to nowhere but here.
---@param body string
---@param content_type string
---@return string[]? flags
---@return string? err set only when `boundary=` is missing from `content_type`
function M.to_curl_flags(body, content_type)
  local boundary = extract_boundary(content_type)
  if not boundary then
    return nil, "multipart/form-data with no boundary= in Content-Type"
  end

  local flags = {}
  for _, part in ipairs(parse_parts(body, boundary)) do
    local name, filename = part_identity(part)
    if name then
      local content, file_ref = part_content(part)
      if file_ref then
        local spec = ("%s=@%s"):format(name, file_ref)
        if filename and filename ~= "" then
          spec = spec .. ";filename=" .. filename
        end
        local ct = part.headers["content-type"]
        if ct then
          spec = spec .. ";type=" .. ct
        end
        flags[#flags + 1] = spec
      else
        flags[#flags + 1] = ("%s=%s"):format(name, content)
      end
    end
  end

  return flags, nil
end

return M
