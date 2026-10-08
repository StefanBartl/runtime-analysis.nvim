-- TESTS/usrcmds_help_spec.lua — every positional argument of `:RA` has a line in lib.nvim's option
-- float (the cheatsheet on the command line, <M-h> after `:RA env `).
--
-- The text comes from the `desc` of each ArgSpec in runtime-analysis.bindings.usrcmds or from the
-- text of an argument's type (`register_type`: RA_ENV_NAME, RA_LOADED_MODULE, RA_PROVENANCE_PATH).
-- An argument added without one shows up as a bare row in the cheatsheet, so this fails until it is
-- described. The verb has no flags and no `key=` pairs.

return function(H)
  local ok, composer = pcall(require, "lib.nvim.bindings.usercmd.composer")
  H.ok(ok, "the composer loads")

  -- A lib.nvim older than `help.undocumented` cannot answer the question; that is a missing
  -- feature of the dependency, not a defect of this plugin.
  if type(composer.help) ~= "table" or type(composer.help.undocumented) ~= "function" then
    return
  end
  local entries = require("lib.nvim.bindings.usercmd.composer.help.entries")

  -- Idempotent (re-registering replaces the verb), so this holds whatever ran before.
  require("runtime-analysis").setup({})
  H.ok(composer.registry().RA ~= nil, ":RA is registered through the composer")

  local missing = {}
  -- `args = true` also lists the positional arguments (an older lib.nvim ignores it).
  for _, m in ipairs(composer.help.undocumented("RA", { args = true })) do
    missing[#missing + 1] = ("%s %s %s"):format(m.route, m.kind, m.name)
  end
  H.eq(
    #missing,
    0,
    ":RA options and arguments without a help text: " .. table.concat(missing, ", ")
  )

  -- The house style of the float: one short line, no trailing full stop.
  local walked = 0
  for _, route in ipairs(composer.registry().RA:spec().routes or {}) do
    for _, arg in ipairs(route.args or {}) do
      local text = entries.arg_desc and entries.arg_desc(arg) or arg.desc
      if text then
        walked = walked + 1
        local label = (":RA %s %s"):format(table.concat(route.path, " "), arg.name)
        H.ok(not text:find("\n", 1, true), label .. " is one line")
        H.ok(#text <= 80, label .. " stays short (" .. #text .. " chars)")
        H.ok(not text:find("%.$"), label .. " has no trailing full stop")
      end
    end
  end
  H.ok(walked > 0, "the routes' argument texts were actually walked")
end
