-- docs/TESTS/init_spec.lua — runtime-analysis's own public surface
--
-- `M.open_request` is this plugin's one stable integration point for
-- another plugin to build on (see its own doc comment) — worth testing
-- directly, not only indirectly through the `:RARequest` command.

return function(H)
  local eq = H.eq

  local ra = require("runtime-analysis")
  ra.setup({})

  -- No argument: the default template.
  do
    ra.open_request()
    local bufnr = vim.api.nvim_get_current_buf()
    eq(vim.bo[bufnr].filetype, "http", "open_request: filetype set on a fresh buffer")
    eq(
      table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "|"),
      "GET https://|",
      "open_request: default template with no argument"
    )
  end

  -- With prefilled lines — what documentation.nvim's Endpoints mode hands
  -- over: method and path, nothing assumed about the base URL.
  do
    ra.open_request({ "GET /users/:id", "" })
    local bufnr = vim.api.nvim_get_current_buf()
    eq(
      table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "|"),
      "GET /users/:id|",
      "open_request: prefilled lines are used verbatim, not merged with the template"
    )
    -- `#lines[1]` is the 0-based column *past* the last character; normal
    -- mode cannot place the cursor there, so Neovim clamps it back onto the
    -- last real character — verified here rather than assumed, since it is
    -- the whole reason this is the last character and not one past it.
    local cursor = vim.api.nvim_win_get_cursor(0)
    eq(
      table.concat(cursor, ","),
      ("1,%d"):format(#"GET /users/:id" - 1),
      "open_request: cursor lands on the last character of the first line"
    )
  end
end
