---@module 'runtime-analysis.curl'
--- curl import/export — `M.parse` turns a pasted
--- `curl` command line (bash-quoted, the shape every API's own docs and
--- every browser's "copy as cURL" already produce) into the same request
--- table `runtime-analysis.parse.parse` returns; `M.format` is the
--- reverse, for sharing a request buffer as a curl command elsewhere.
---
--- **Import is the higher-value half by a lot**, per the roadmap entry's
--- own note, and most of this module is import's real argument parsing —
--- a genuine (if bounded) tokenizer, not string templating. No shared
--- shell-tokenizer exists anywhere in lib.nvim (checked before writing
--- this), so `tokenize` below is this module's own: single-quoted strings
--- (literal, bash semantics — nothing inside is special, not even a
--- backslash), double-quoted strings (`\"`, `\\`, `` \$ ``, `` \` `` are
--- the only recognized escapes, matching bash's own double-quote rules),
--- an unquoted backslash escaping exactly the next character, and
--- whitespace as the separator outside any quoting. No `$VAR` expansion,
--- no command substitution — a pasted, static curl command has no
--- business containing either, and if one somehow does, it passes through
--- literally rather than this module pretending to be a shell.

local base64 = require("lib.lua.strings.encoding")

local M = {}

---Bash line-continuation (`\` at end of line) joined into one logical
---line before tokenizing — the shape every multi-header "copy as cURL"
---snippet actually pastes as.
---@internal
---@param cmd string
---@return string
local function join_continuations(cmd)
  return (cmd:gsub("\\[ \t]*\r?\n", " "))
end

---@internal
---@param cmd string
---@return string[]
local function tokenize(cmd)
  local tokens = {}
  local buf = {}
  local has_token = false
  local i, n = 1, #cmd

  local function flush()
    if has_token then
      tokens[#tokens + 1] = table.concat(buf)
      buf = {}
      has_token = false
    end
  end

  while i <= n do
    local c = cmd:sub(i, i)
    if c == "'" then
      has_token = true
      local close = cmd:find("'", i + 1, true)
      if not close then
        buf[#buf + 1] = cmd:sub(i + 1)
        i = n + 1
      else
        buf[#buf + 1] = cmd:sub(i + 1, close - 1)
        i = close + 1
      end
    elseif c == '"' then
      has_token = true
      i = i + 1
      while i <= n do
        local d = cmd:sub(i, i)
        if d == '"' then
          i = i + 1
          break
        elseif d == "\\" and i < n and cmd:sub(i + 1, i + 1):find('["\\$`]') then
          buf[#buf + 1] = cmd:sub(i + 1, i + 1)
          i = i + 2
        else
          buf[#buf + 1] = d
          i = i + 1
        end
      end
    elseif c == "\\" and i < n then
      has_token = true
      buf[#buf + 1] = cmd:sub(i + 1, i + 1)
      i = i + 2
    elseif c:match("%s") then
      flush()
      i = i + 1
    else
      has_token = true
      buf[#buf + 1] = c
      i = i + 1
    end
  end
  flush()
  return tokens
end
M._tokenize = tokenize -- test-only

---Flags that consume the following token as a value, and what that value
---means. `"ignore"` is a flag curl itself understands but that has no
---representation in this plugin's request shape (output redirection,
---timeouts, TLS material, ...) — listed explicitly and consumed anyway so
---its value is never mistaken for the URL. Not exhaustive: a *truly*
---unrecognized value-flag is the one real gap this parser has (see the
---fallback branch in `M.parse` below).
---@type table<string, string>
local VALUE_FLAGS = {
  ["-X"] = "method",
  ["--request"] = "method",
  ["-H"] = "header",
  ["--header"] = "header",
  ["-d"] = "data",
  ["--data"] = "data",
  ["--data-raw"] = "data",
  ["--data-binary"] = "data",
  ["--data-ascii"] = "data",
  -- Real curl URL-encodes this value; that step is not replicated here —
  -- an honest, stated gap rather than a silent wrong answer, since a
  -- common `key=plain-value` case still comes out identical either way.
  ["--data-urlencode"] = "data",
  ["-u"] = "auth",
  ["--user"] = "auth",
  ["-b"] = "cookie",
  ["--cookie"] = "cookie",
  ["-A"] = "user_agent",
  ["--user-agent"] = "user_agent",
  ["-e"] = "referer",
  ["--referer"] = "referer",
  ["--url"] = "url",
  ["-o"] = "ignore",
  ["--output"] = "ignore",
  ["-w"] = "ignore",
  ["--write-out"] = "ignore",
  ["-m"] = "ignore",
  ["--max-time"] = "ignore",
  ["--connect-timeout"] = "ignore",
  ["--retry"] = "ignore",
  ["--cacert"] = "ignore",
  ["--cert"] = "ignore",
  ["--key"] = "ignore",
  ["-c"] = "ignore",
  ["--cookie-jar"] = "ignore",
}

---Flags that take no value at all — recognized so they are never
---mistaken for an unrecognized value-flag whose argument would otherwise
---get consumed. Every one of these is meaningless to a request this
---plugin sends itself (verbosity, redirect-following, TLS verification,
---IP version, ...), so all are simply dropped.
---@type table<string, true>
local BOOL_FLAGS = {}
for _, f in ipairs({
  "-s",
  "--silent",
  "-S",
  "--show-error",
  "-v",
  "--verbose",
  "-k",
  "--insecure",
  "-L",
  "--location",
  "--compressed",
  "-i",
  "--include",
  "-f",
  "--fail",
  "-G",
  "--get",
  "-#",
  "--progress-bar",
  "-4",
  "--ipv4",
  "-6",
  "--ipv6",
  "--http1.1",
  "--http2",
}) do
  BOOL_FLAGS[f] = true
end

---Parse a pasted `curl` command line into the same request shape
---`runtime-analysis.parse.parse` returns.
---@param cmd string
---@return { method: string, url: string, headers: table<string, string>, body: string? }? request
---@return string? err
function M.parse(cmd)
  local tokens = tokenize(join_continuations(cmd))

  -- A leading `curl`/`curl.exe` token is dropped; a paste that already
  -- omits it (everything copied *after* `curl `) works identically either
  -- way — this module never requires either shape specifically.
  if tokens[1] and (tokens[1] == "curl" or tokens[1]:lower() == "curl.exe") then
    table.remove(tokens, 1)
  end

  if #tokens == 0 then
    return nil, "empty curl command"
  end

  local url
  local method
  local headers = {}
  local data_parts = {}

  local i = 1
  while i <= #tokens do
    local tok = tokens[i]
    local kind = VALUE_FLAGS[tok]
    if kind then
      local value = tokens[i + 1]
      if value == nil then
        return nil, ("%s expects a value"):format(tok)
      end
      if kind == "method" then
        method = value:upper()
      elseif kind == "header" then
        local name, hval = value:match("^([^:]+):%s*(.*)$")
        if name then
          headers[vim.trim(name)] = hval
        end
      elseif kind == "data" then
        data_parts[#data_parts + 1] = value
      elseif kind == "auth" then
        headers["Authorization"] = "Basic " .. base64.base64_encode(value)
      elseif kind == "cookie" then
        headers["Cookie"] = value
      elseif kind == "user_agent" then
        headers["User-Agent"] = value
      elseif kind == "referer" then
        headers["Referer"] = value
      elseif kind == "url" then
        url = value
      end
      -- "ignore": consumed, nothing recorded.
      i = i + 2
    elseif BOOL_FLAGS[tok] then
      i = i + 1
    elseif tok:sub(1, 1) == "-" then
      -- An unrecognized flag: treated as boolean, the safer of two wrong
      -- guesses. Swallowing the next token as this flag's own value risks
      -- eating the real URL if the guess is wrong; leaving it instead
      -- means it is picked up as a stray positional on the next
      -- iteration — visible (a garbled request) rather than a silently
      -- lost URL.
      i = i + 1
    else
      if not url then
        url = tok
      end
      i = i + 1
    end
  end

  if not url then
    return nil, "no URL found in the curl command"
  end

  local body
  if #data_parts > 0 then
    body = table.concat(data_parts, "&")
    if not method then
      -- curl's own default: any -d/--data implies POST unless -X said
      -- otherwise, and that default is replicated here rather than left
      -- for the reader to notice the buffer says GET with a body.
      method = "POST"
    end
  end

  return {
    method = method or "GET",
    url = url,
    headers = headers,
    body = body,
  },
    nil
end

---POSIX single-quote escaping: close the quote, emit a literal escaped
---quote, reopen — the portable way to embed an arbitrary string in a
---single-quoted shell token. Deliberately not `vim.fn.shellescape`, which
---escapes for Neovim's own `&shell` (cmd.exe/PowerShell syntax on
---Windows) — wrong here, since a curl command is bash/POSIX syntax
---regardless of which OS this plugin happens to run on, and `M.format`'s
---whole point is producing something safe to paste into any real shell or
---share verbatim in a doc.
---@internal
---@param s string
---@return string
local function shq(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

---@internal
---@param headers table<string, string>
---@return string?
local function content_type_of(headers)
  for name, value in pairs(headers or {}) do
    if name:lower() == "content-type" then
      return value
    end
  end
  return nil
end

---The reverse of `M.parse`: a request table back into a runnable,
---shareable `curl` command line, multi-line for readability (the same
---shape a browser's own "copy as cURL" produces). **Never resolves
---`{{var}}` placeholders** — `bindings/usrcmds.lua` hands this the raw,
---unresolved request for exactly the reason `runtime-analysis.env`'s own
---doc-comment states its trap: a `{{token}}` must render as `{{token}}`
---everywhere a request is shown or shared, and export is exactly that, no
---different from request history or the "sending ..." placeholder.
---
---A multipart/form-data body is never emitted as
---`--data-raw`: a file reference's real bytes are not safe, shareable
---shell text, and `runtime-analysis.multipart.to_curl_flags` already
---turns each part into curl's own `-F "field=@path"` shape instead, which
---reads the file itself when the command actually runs rather than
---inlining it now. A malformed multipart body (no `boundary=`) falls back
---to `--data-raw` with the literal, unresolved text — a degraded but
---honest export beats silently dropping the body.
---@param request { method: string, url: string, headers: table<string, string>, body: string? }
---@return string
function M.format(request)
  local parts = { "curl " .. shq(request.url) }

  if request.method and request.method ~= "GET" then
    parts[#parts + 1] = "-X " .. request.method
  end

  local names = vim.tbl_keys(request.headers or {})
  table.sort(names)
  for _, name in ipairs(names) do
    parts[#parts + 1] = ("-H %s"):format(shq(name .. ": " .. request.headers[name]))
  end

  local content_type = content_type_of(request.headers)
  local flags
  if content_type and request.body then
    local multipart = require("runtime-analysis.multipart")
    if multipart.is_multipart(request.headers) then
      flags = multipart.to_curl_flags(request.body, content_type)
    end
  end

  if flags then
    for _, flag in ipairs(flags) do
      parts[#parts + 1] = "-F " .. shq(flag)
    end
  elseif request.body then
    parts[#parts + 1] = "--data-raw " .. shq(request.body)
  end

  return table.concat(parts, " \\\n  ")
end

return M
