---@module 'runtime-analysis.env'
--- Variables and environments — docs/ROADMAP.md §2.1. `{{baseUrl}}` inside a
--- request buffer's URL, header values or body resolves against a *named*
--- environment (`dev`/`staging`/`prod`, or any name a project's own files
--- define), selected with `:RA env <name>`.
---
--- Two per-project JSON files at the project root — the same split
--- IntelliJ's HTTP Client already uses for exactly this problem, matched
--- rather than invented, the same reasoning `docs/ROADMAP.md`'s "Deliberately
--- not: owning the .http filetype" already gives for `parse.lua`'s own shape:
---
---   http-client.env.json          shared, safe to commit — non-secret
---                                  defaults (a baseUrl, a tenant id)
---   http-client.private.env.json  gitignored, per-machine — the file a
---                                  real token belongs in
---
--- Both are optional and are merged per environment name, the private
--- file's own keys winning on overlap: a project can commit only the shared
--- file and every reader still gets working defaults; a reader who also has
--- the private file gets their own secrets layered on top of those.
---
--- **The trap, stated in the roadmap entry this ships:** resolution happens
--- exactly once, in `M.resolve`, immediately before a request is handed to
--- curl — see `bindings/usrcmds.lua`'s own `send_current_buffer`, which
--- keeps the raw, unresolved request (`{{token}}` still literal) for
--- everything else: the "sending ..." placeholder and request history both
--- show/record the placeholder text, never the real value. `M.resolve`
--- itself never logs or notifies a resolved value either.

local find_root = require("lib.nvim.fs.find_root")
local is_readable_file = require("lib.nvim.fs.is_readable_file")
local json = require("lib.nvim.fs.json")
local read = require("lib.nvim.fs.read")

local M = {}

local SHARED_FILE = "http-client.env.json"
local PRIVATE_FILE = "http-client.private.env.json"

local finder = find_root({ markers = { ".git" } })

---@return string
local function default_root()
  local from = (vim.uv or vim.loop).cwd() or vim.fn.getcwd()
  return finder.find(from) or from
end

---@param opts? { root: string? }
---@return string
local function resolve_root(opts)
  return (opts and opts.root) or default_root()
end

---@param path string
---@return table<string, table<string, any>>
local function read_env_file(path)
  if not is_readable_file(path) then
    return {}
  end
  local decoded = json.read(path)
  return decoded or {}
end

-- Warn at most once per session — a nudge, not a repeated nag every time a
-- request happens to use a variable.
local warned_gitignore = false

---Best-effort nudge, not a real gitignore scan: warns once if the private
---env file exists on disk but its own filename does not appear anywhere in
---the project's `.gitignore` — the "must be gitignore-able by default" half
---of the trap this feature's roadmap entry names up front. A substring
---check against the file's raw content, not a pattern matcher (a broader
---rule like `*.private.env.json` would also cover it and this check would
---miss that and warn anyway) — cheap insurance, not a guarantee, and never
---itself an error.
---@param root string
local function warn_if_not_gitignored(root)
  if warned_gitignore then
    return
  end
  local private_path = root .. "/" .. PRIVATE_FILE
  if not is_readable_file(private_path) then
    return
  end
  local gitignore_content = read(root .. "/.gitignore") or ""
  if gitignore_content:find(PRIVATE_FILE, 1, true) then
    return
  end
  warned_gitignore = true
  vim.notify(
    ("runtime-analysis: %s exists but is not in .gitignore — add it before committing"):format(
      PRIVATE_FILE
    ),
    vim.log.levels.WARN
  )
end

---Every environment this project defines, shared and private merged per
---name — private keys win on overlap. Re-read from disk on every call, no
---caching: both files are small and hand-edited, and a stale in-memory copy
---surviving an edit would be a worse default than a cheap re-read.
---@param opts? { root: string? } `root` overrides the discovered project
---root — real callers never need this; it exists so a test can point this
---module at an isolated directory instead of a real project, the same
---reason `history.lua`'s own `opts.dir` exists.
---@return table<string, table<string, any>>
function M.load_all(opts)
  local root = resolve_root(opts)
  warn_if_not_gitignored(root)
  local shared = read_env_file(root .. "/" .. SHARED_FILE)
  local private = read_env_file(root .. "/" .. PRIVATE_FILE)

  local names = {}
  for name in pairs(shared) do
    names[name] = true
  end
  for name in pairs(private) do
    names[name] = true
  end

  local out = {}
  for name in pairs(names) do
    out[name] = vim.tbl_deep_extend("force", shared[name] or {}, private[name] or {})
  end
  return out
end

---@param opts? { root: string? } See `M.load_all`.
---@return string[] sorted
function M.list_names(opts)
  local names = {}
  for name in pairs(M.load_all(opts)) do
    names[#names + 1] = name
  end
  table.sort(names)
  return names
end

---@type string?
local current_name = nil

---@return string?
function M.current()
  return current_name
end

---Select the active environment for this session. Not persisted across
---restarts, on purpose — the same "session state, not saved state"
---`bindings/usrcmds.lua`'s own pending-request tracking already uses for
---the identical reason: which environment you meant is a fact about *this*
---editing session, not one worth writing to disk.
---@param name string
---@param opts? { root: string? } See `M.load_all`.
---@return boolean ok
---@return string? err
function M.set_current(name, opts)
  if not M.load_all(opts)[name] then
    local names = M.list_names(opts)
    local available = #names > 0 and table.concat(names, ", ") or "(none defined)"
    return false, ("no environment %q — available: %s"):format(name, available)
  end
  current_name = name
  return true, nil
end

---Every `{{name}}` placeholder in `str`, deduplicated, first-seen order.
---@param str string
---@return string[]
local function find_placeholders(str)
  local seen = {}
  local out = {}
  for name in str:gmatch("{{%s*([%w_.%-]+)%s*}}") do
    if not seen[name] then
      seen[name] = true
      out[#out + 1] = name
    end
  end
  return out
end

---@param str string
---@param vars table<string, any>
---@return string
local function substitute(str, vars)
  return (str:gsub("{{%s*([%w_.%-]+)%s*}}", function(name)
    return tostring(vars[name])
  end))
end

---Resolve every `{{name}}` placeholder in `request`'s url, header values and
---body against the currently selected environment, returning a *new*
---request table — `request` itself is never mutated, so a caller keeping
---the original around (for history, for the "sending ..." placeholder)
---keeps the literal `{{name}}` text exactly as typed.
---
---A request with no placeholders at all resolves to an unchanged copy with
---no error, even with no environment selected — plain requests, the common
---case, are entirely unaffected by this feature existing.
---@param request { method: string, url: string, headers: table<string, string>, body: string? }
---@param opts? { root: string? } See `M.load_all`.
---@return { method: string, url: string, headers: table<string, string>, body: string? }? resolved
---@return string? err
function M.resolve(request, opts)
  local names = {}
  vim.list_extend(names, find_placeholders(request.url))
  for _, value in pairs(request.headers) do
    vim.list_extend(names, find_placeholders(value))
  end
  if request.body then
    vim.list_extend(names, find_placeholders(request.body))
  end

  if #names == 0 then
    return vim.deepcopy(request), nil
  end

  if not current_name then
    local available = M.list_names(opts)
    return nil,
      ("request uses {{%s}} but no environment is selected — run :RA env <name> (available: %s)"):format(
        table.concat(names, "}}, {{"),
        #available > 0 and table.concat(available, ", ") or "none defined"
      )
  end

  local vars = M.load_all(opts)[current_name] or {}
  local missing = {}
  for _, name in ipairs(names) do
    if vars[name] == nil then
      missing[#missing + 1] = name
    end
  end
  if #missing > 0 then
    return nil,
      ("environment %q has no value for: %s"):format(current_name, table.concat(missing, ", "))
  end

  local headers = {}
  for name, value in pairs(request.headers) do
    headers[name] = substitute(value, vars)
  end

  return {
    method = request.method,
    url = substitute(request.url, vars),
    headers = headers,
    body = request.body and substitute(request.body, vars) or nil,
  },
    nil
end

---Shared, safe-to-commit environment file name, relative to the project root.
---@type string
M.SHARED_FILE = SHARED_FILE

---Gitignored, per-machine environment file name, relative to the project root.
---@type string
M.PRIVATE_FILE = PRIVATE_FILE

---Test-only: drop the selected environment back to "none". Real callers
---never need this — a session's own choice should persist for the rest of
---that session — it exists purely so `env_spec.lua` can start each `do`
---block from a known state without depending on the order specs run in.
function M._reset_for_test()
  current_name = nil
  warned_gitignore = false
end

return M
