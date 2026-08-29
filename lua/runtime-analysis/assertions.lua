---@module 'runtime-analysis.assertions'
--- Response assertions — `# @expect status 200` (or
--- `// @expect status 200`), checked once a real response arrives, a
--- mismatch surfaced via the quickfix list rather than only a `vim.notify`
--- easy to miss. Deliberately narrow, per the roadmap entry's own stated
--- limit: "is this endpoint still 200," not a general assertion language —
--- one directive, one thing it can check, on purpose.

local M = {}

local PATTERN = "^%s*[#/]+%s*@expect%s+status%s+(%d+)%s*$"

---Find the `@expect status N` directive in a request block's own lines, if
---any — scanned *before* `runtime-analysis.parse` ever sees the block,
---since that module has no comment syntax of its own. At most one per
---block: a second is a real error (ambiguous, not "last one wins"
---silently), the same fail-loud stance `parse.parse` already takes on a
---malformed header line.
---@param lines string[]
---@return { status: integer, line: integer }? found `line` is 1-based,
---relative to `lines` — translating it into an absolute buffer line (for a
---quickfix entry) is the caller's job, since this module never sees the
---buffer itself.
---@return string? err
function M.extract(lines)
  local found
  for i, line in ipairs(lines) do
    local status = line:match(PATTERN)
    if status then
      if found then
        return nil,
          ("more than one @expect status directive (lines %d and %d)"):format(found.line, i)
      end
      found = { status = tonumber(status), line = i }
    end
  end
  return found, nil
end

---`lines` with every `@expect` directive line removed. Required before
---handing a block to `runtime-analysis.parse.parse`: left in, a directive
---as the block's first line would fail "first non-blank line must be
---METHOD url"; anywhere among the headers it would fail the header-line
---pattern instead (it has no `Name:` to match).
---@param lines string[]
---@return string[]
function M.strip(lines)
  local out = {}
  for _, line in ipairs(lines) do
    if not line:match(PATTERN) then
      out[#out + 1] = line
    end
  end
  return out
end

return M
