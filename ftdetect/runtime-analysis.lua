-- ftdetect/runtime-analysis.lua — docs/ROADMAP.md §1.4.
--
-- `*.http` already resolves to filetype `http` in stock Neovim (verified:
-- `vim.filetype.match({ filename = "x.http" })` answers `"http"` with no
-- plugin at all) — the one real gap is `*.rest`, IntelliJ HTTP Client's own
-- extension for the identical file shape. Sourced automatically by
-- Neovim's own `:filetype on` (every `ftdetect/*.lua` on the runtimepath
-- is), independent of whether `require("runtime-analysis").setup()` has
-- run yet — the same reason a plugin lazy-loaded on `ft = "http"` still
-- needs its filetype detected before it can ever be loaded on it.
--
-- Not owning `.http`/`.rest` outright (docs/ROADMAP.md's own "Deliberately
-- not building" table already states that rule) — this maps `.rest` onto
-- the *existing* `http` filetype both this plugin and VS Code's REST
-- Client already use, rather than inventing a filetype of its own.

vim.filetype.add({
  extension = {
    rest = "http",
  },
})
