-- TESTS/init_spec.lua — runtime-analysis's own public surface
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

  -- ERR-02: this is the plugin's one public integration surface, so a
  -- caller's malformed argument -- an explicit empty table, a non-table, a
  -- table with a non-string entry -- must fall back to the default
  -- template rather than raise from inside this plugin.
  do
    for _, bad in ipairs({ {}, "not a table", 42, { "ok line", 7 } }) do
      ra.open_request(bad)
      local bufnr = vim.api.nvim_get_current_buf()
      eq(
        table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "|"),
        "GET https://|",
        "open_request: falls back to the default template on a malformed argument"
      )
    end
  end

  -- ERR-22: `opts.request_filetype`'s KEY is checked at setup() (config.
  -- validate), but its VALUE never was -- a non-string value used to reach
  -- `vim.bo[bufnr].filetype = ...` unfiltered and raise "Invalid value for
  -- option 'filetype'", aborting `:RARequest` entirely instead of
  -- degrading to the documented default ("http").
  do
    local warned
    local orig_notify = vim.notify
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(msg, level)
      warned = { msg = msg, level = level }
    end

    ---@diagnostic disable-next-line: assign-type-mismatch
    ra.setup({ request_filetype = 42 })
    H.ok(
      pcall(ra.open_request),
      "ERR-22: a non-string request_filetype degrades instead of crashing"
    )
    local bufnr = vim.api.nvim_get_current_buf()
    eq(vim.bo[bufnr].filetype, "http", "open_request: falls back to the default filetype")
    H.ok(warned ~= nil, "open_request: a non-string request_filetype still warns")

    vim.notify = orig_notify
    ra.setup({})
  end
end
