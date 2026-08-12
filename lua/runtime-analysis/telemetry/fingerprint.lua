---@module 'runtime-analysis.telemetry.fingerprint'
--- Turns a call's arguments into a short, bounded, non-secret string key.
---
--- Deliberately NOT a serializer. Argument profiling exists to answer "do most
--- calls pass the same thing?", and that question is answerable from a shape
--- plus a truncated scalar. Storing the real values would mean writing file
--- paths, buffer contents and possibly tokens into `stdpath("cache")` — a
--- profiler that does that is a security bug wearing a feature's name.
---
--- Rules (see lua/lib/nvim/telemetry/README.md, "Argument profiling, done honestly"):
---   nil/boolean/number/short string -> the value itself
---   long string                     -> truncated with an ellipsis marker
---   table                           -> "<table:n=3>" (shape, not contents)
---   function/userdata/thread        -> "<function>" / "<userdata>" / "<thread>"

local M = {}

--- Longer than this and a string is truncated. 40 keeps a typical project path
--- recognizable ("/home/u/repos/lib.nvi…") while bounding the stored size.
local MAX_STRING = 40

--- Beyond this many arguments the tail is summarized rather than described;
--- variadic call sites otherwise produce one distinct fingerprint per arity.
local MAX_ARGS = 4

---Byte length `<= max_len` that still lands on a UTF-8 character boundary.
---
---`v:sub(1, MAX_STRING)` alone cuts by byte count, and a call argument is not
---guaranteed to have an ASCII byte sitting exactly at that offset — a project
---path with a non-ASCII directory name, a docstring, anything outside 7-bit
---ASCII. Cutting mid-character writes an invalid UTF-8 continuation byte into
---the stored fingerprint, which then sits in `stdpath("cache")` as a string
---no JSON/Markdown reader downstream can round-trip correctly. Found exactly
---this way: a real telemetry file for documentation.nvim, argument text
---containing "→" (U+2192, 3 bytes), split after its first byte.
---
---A byte is a UTF-8 continuation byte iff its top two bits are `10`
---(`0x80`-`0xBF`). Walking backward from `max_len` until the byte *after* the
---cut is not a continuation byte finds the nearest boundary at or before it —
---so this only ever shortens the truncation, never lengthens it past
---`max_len`.
---@param s string
---@param max_len integer
---@return integer
local function utf8_boundary(s, max_len)
  local k = max_len
  while k > 0 do
    local b = s:byte(k + 1)
    if not b or b < 0x80 or b >= 0xC0 then
      break
    end
    k = k - 1
  end
  return k
end

---@param v any
---@return string
function M.value(v)
  local t = type(v)

  if v == nil then
    return "nil"
  elseif t == "boolean" or t == "number" then
    return tostring(v)
  elseif t == "string" then
    if #v <= MAX_STRING then
      return ("%q"):format(v)
    end
    return ("%q…"):format(v:sub(1, utf8_boundary(v, MAX_STRING)))
  elseif t == "table" then
    -- Shape only. `#v` is cheap; a full pair count on a large table is not,
    -- and this runs on every profiled call.
    local n = #v
    if n > 0 then
      return ("<table:#%d>"):format(n)
    end
    return next(v) == nil and "<table:empty>" or "<table:map>"
  end

  return ("<%s>"):format(t)
end

---Fingerprint a whole argument list.
---@param n integer  # result of select("#", ...) at the call site
---@param ... any
---@return string
function M.of(n, ...)
  if n == 0 then
    return "()"
  end

  local parts = {}
  local shown = n < MAX_ARGS and n or MAX_ARGS
  for i = 1, shown do
    parts[i] = M.value((select(i, ...)))
  end
  if n > shown then
    parts[shown + 1] = ("…+%d"):format(n - shown)
  end

  return "(" .. table.concat(parts, ", ") .. ")"
end

M.MAX_STRING = MAX_STRING
M.MAX_ARGS = MAX_ARGS

return M
