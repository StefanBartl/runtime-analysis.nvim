-- docs/TESTS/run.lua — headless test runner for runtime-analysis.nvim.
--
-- Run from the repo root:
--   nvim --headless -u NONE -l docs/TESTS/run.lua
--
-- Loads every *_spec.lua listed below, runs it against the shared harness,
-- prints a per-spec result, and exits non-zero on the first failing spec.

-- Make the repo importable whether invoked via -l (cwd) or luafile.
vim.opt.rtp:append(vim.fn.getcwd())

-- lib.nvim is a runtime dependency (net.curl), so the specs cannot run
-- without it on the rtp. Three ways it can be found, in descending order of
-- explicitness — CI uses the first, a local checkout the second, an
-- installed plugin manager the third (already on the rtp, so nothing to
-- do). Candidates built with explicit indices, not a `{a, b, c}` literal fed
-- to `ipairs`: `LIB_NVIM_DIR` is `nil` whenever unset (the normal case for
-- CI), and a `nil` in a table literal's first slot makes `ipairs` stop
-- immediately without inspecting the slots after it — a real bug, found
-- and fixed this same way in documentation.nvim's own copy of this file
-- (see that repo's FEATURES.md), not repeated here.
local function add_lib_nvim()
  if pcall(require, "lib.nvim.net.curl") then
    return
  end
  local candidates = {}
  if vim.env.LIB_NVIM_DIR and vim.env.LIB_NVIM_DIR ~= "" then
    candidates[#candidates + 1] = vim.env.LIB_NVIM_DIR
  end
  candidates[#candidates + 1] = vim.fn.getcwd() .. "/.deps/lib.nvim"
  candidates[#candidates + 1] = vim.fs.dirname(vim.fn.getcwd()) .. "/lib.nvim"
  for _, dir in ipairs(candidates) do
    if dir and vim.fn.isdirectory(dir) == 1 then
      vim.opt.rtp:append(dir)
      if pcall(require, "lib.nvim.net.curl") then
        return
      end
    end
  end
  io.stderr:write("docs/TESTS/run.lua: lib.nvim not found.\n")
  io.stderr:write("  Set LIB_NVIM_DIR, or clone it to .deps/lib.nvim, or beside this repo.\n")
  os.exit(1)
end

add_lib_nvim()

local dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local H = dofile(dir .. "harness.lua")

local specs = {
  "parse_spec.lua",
  "runner_spec.lua",
  "view_spec.lua",
  "init_spec.lua",
  "usrcmds_spec.lua",
  "history_spec.lua",
  "env_spec.lua",
  "curl_spec.lua",
  "assertions_spec.lua",
  "telemetry_spec.lua",
  "lazy_spec.lua",
}

--- Straight to stdout rather than through `print` — the same reason
--- documentation.nvim's own runner gives: `print` in a headless Neovim goes
--- through the message area, and a spec that opens a window (`view_spec`
--- opens a real split) forces a redraw that swallows the pending newline.
---@param s string
local function say(s)
  io.stdout:write(s, "\n")
end

local failed = 0
for _, name in ipairs(specs) do
  local run = dofile(dir .. name)
  local ok, err = pcall(run, H)
  if ok then
    say(("ok    %s"):format(name))
  else
    failed = failed + 1
    say(("FAIL  %s\n      %s"):format(name, tostring(err)))
  end
end

if failed > 0 then
  say(("\n%d spec(s) failed"):format(failed))
  os.exit(1)
end

say("\nRUNTIME_ANALYSIS_TESTS_OK")
