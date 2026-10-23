-- TESTS/float_spec.lua — runtime-analysis.ui.float
--
-- The float itself (winbar legend, `?` cheatsheet, keymaps) is a `ui.kit.viewer`
-- feature and is specified in ui.nvim. What belongs to this plugin, and is
-- pinned here against a recording stand-in for the kit: which keys a call
-- hands over, in which order, what they do when run, the options that are
-- passed through, and the fallback to the message area when the kit is
-- absent or too old to carry viewer keys.

return function(H)
  local eq, ok = H.eq, H.ok

  local saved = {
    kit = package.loaded["ui.kit"],
    vk = package.loaded["ui.kit.viewer_keys"],
    float = package.loaded["runtime-analysis.ui.float"],
    notify = package.loaded["lib.nvim.notify"],
  }

  ---@type table|nil
  local opened
  local function install_kit()
    opened = nil
    package.loaded["ui.kit"] = {
      viewer = function(o)
        opened = o
        return {}
      end,
    }
    package.loaded["ui.kit.viewer_keys"] = {}
    package.loaded["runtime-analysis.ui.float"] = nil
    return require("runtime-analysis.ui.float")
  end

  local function find(keys, lhs)
    for _, k in ipairs(keys) do
      if k.lhs == lhs then
        return k
      end
    end
  end

  local function lhs_list(keys)
    local out = {}
    for _, k in ipairs(keys) do
      out[#out + 1] = k.lhs
    end
    return table.concat(out, ",")
  end

  -- A view with the viewer's `view`: records what a key does to it.
  local function fake_view()
    local view = { bufnr = 7, winid = 8, lines = nil, title = nil }
    view.set_lines = function(l)
      view.lines = l
    end
    view.set_title = function(t)
      view.title = t
    end
    return view
  end

  -- keys are derived only from the handlers this call has -------------------
  local float = install_kit()
  float.show({ "a", "b" }, "Report")
  eq(lhs_list(opened.keys), "", "no handlers -> no keys (the kit still adds `?`)")
  eq(opened.title, " Report ", "the title is padded")
  eq(opened.help_title, "Report", "the cheatsheet is titled with the plain title")
  eq(opened.help_filetype, "runtime-analysis-help", "the cheatsheet keeps its filetype")
  eq(opened.desc_prefix, "runtime-analysis", "the default keymap description prefix")
  eq(opened.table_view, nil, "table_view is only on when asked")
  ok(opened.width >= 60 and opened.width <= 110, "width within 60..110")

  float.show({ "a" }, "Report", {
    on_refresh = function() end,
    on_drilldown = function() end,
    row_key_at = function() end,
    on_open_html = function() end,
    keys = { { lhs = "x", desc = "Extra", run = function() end } },
    desc_prefix = "ra-startup",
    table_view = true,
  })
  eq(lhs_list(opened.keys), "r,<CR>,gO,x", "built-in keys first, then the caller's")
  eq(opened.desc_prefix, "ra-startup", "the caller's prefix is passed on")
  eq(opened.table_view, true, "table_view is passed on")
  eq(find(opened.keys, "r").legend, "Refresh", "refresh is advertised")
  eq(find(opened.keys, "<CR>").legend, "Open", "drill-down is advertised")
  eq(find(opened.keys, "gO").legend, "HTML", "the HTML export is advertised")
  eq(find(opened.keys, "x").legend, nil, "an extra key without a legend is not advertised")

  -- refresh -----------------------------------------------------------------
  local fresh = { "new" }
  float.show({ "a" }, "R", {
    on_refresh = function()
      return fresh
    end,
  })
  local view = fake_view()
  find(opened.keys, "r").run(view)
  eq(view.lines, fresh, "refresh installs the fresh lines")
  fresh = nil
  view = fake_view()
  find(opened.keys, "r").run(view)
  eq(view.lines, nil, "a refresh that returns nothing leaves the float as it is")

  -- drill-down --------------------------------------------------------------
  local asked
  float.show({ "a" }, "R", {
    row_key_at = function(line)
      return line ~= "" and ("key:" .. line) or nil
    end,
    on_drilldown = function(key)
      asked = key
      return { "detail" }, "Detail"
    end,
  })
  vim.cmd("enew")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "ns1  —  on" })
  view = fake_view()
  find(opened.keys, "<CR>").run(view)
  eq(asked, "key:ns1  —  on", "the key is read off the line under the cursor")
  eq(view.lines[1], "detail", "the float is swapped to the drill-down lines")
  eq(view.title, " Detail ", "...and titled")

  asked = nil
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "" })
  view = fake_view()
  find(opened.keys, "<CR>").run(view)
  eq(asked, nil, "a line without a key does nothing")
  eq(view.lines, nil, "...and leaves the float alone")

  float.show({ "a" }, "R", {
    on_drilldown = function()
      asked = "called"
    end,
  })
  asked = nil
  find(opened.keys, "<CR>").run(fake_view())
  eq(asked, nil, "without row_key_at the drill-down never fires")

  -- HTML export and extra keys ---------------------------------------------
  local html = 0
  local got
  float.show({ "a" }, "R", {
    on_open_html = function()
      html = html + 1
    end,
    keys = {
      {
        lhs = "x",
        desc = "Extra",
        run = function(bufnr, set_lines, set_title)
          got = { bufnr = bufnr }
          set_lines({ "from x" })
          set_title("X view")
        end,
      },
    },
  })
  find(opened.keys, "gO").run(fake_view())
  eq(html, 1, "gO runs the export")
  view = fake_view()
  find(opened.keys, "x").run(view)
  eq(got.bufnr, 7, "an extra key is run with the buffer")
  eq(view.lines[1], "from x", "...and the line setter")
  eq(view.title, " X view ", "...and a title setter that pads like the first title")

  -- decoration hook is passed through, not wrapped ---------------------------
  local hook = function() end
  float.show({ "a" }, "R", { on_lines = hook })
  eq(opened.on_lines, hook, "on_lines goes to the kit, which re-runs it after every refresh")

  -- fallback -----------------------------------------------------------------
  local messages = {}
  package.loaded["lib.nvim.notify"] = {
    create = function()
      return {
        info = function(msg)
          messages[#messages + 1] = msg
        end,
      }
    end,
  }

  package.loaded["ui.kit"] = nil
  package.loaded["ui.kit.viewer_keys"] = nil
  package.loaded["runtime-analysis.ui.float"] = nil
  local real_require = require
  ---@diagnostic disable-next-line: duplicate-set-field
  _G.require = function(name)
    if name == "ui.kit" or name == "ui.kit.viewer_keys" then
      error("module '" .. name .. "' not found")
    end
    return real_require(name)
  end
  local fell_back = real_require("runtime-analysis.ui.float")
  fell_back.show({ "line 1", "line 2" }, "Report")
  eq(messages[1], "line 1\nline 2", "no kit: the report arrives in the message area")

  -- a kit without viewer keys (an older ui.nvim) is no kit for this float
  messages = {}
  package.loaded["ui.kit"] = {
    viewer = function()
      error("must not open a float that lacks its keys")
    end,
  }
  _G.require = function(name)
    if name == "ui.kit.viewer_keys" then
      error("module '" .. name .. "' not found")
    end
    return real_require(name)
  end
  fell_back.show({ "x" }, "Report")
  eq(messages[1], "x", "an old kit without viewer keys: message area, no keyless float")
  _G.require = real_require

  package.loaded["ui.kit"] = saved.kit
  package.loaded["ui.kit.viewer_keys"] = saved.vk
  package.loaded["runtime-analysis.ui.float"] = saved.float
  package.loaded["lib.nvim.notify"] = saved.notify
end
