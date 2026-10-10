-- TESTS/history_spec.lua — runtime-analysis.history
--
-- Every call passes an isolated `opts = { dir = ... }` so this never
-- touches the real stdpath("cache") — the same reason telemetry_spec.lua
-- exercises `runtime-analysis.telemetry.new({ dir = ... })` rather than the
-- default. `M.record`/`M.list`/`M.clear` all resolve the same project-keyed
-- cache_key internally regardless of `opts.dir`, so what actually proves
-- isolation here is that a fresh `dir` per `do` block starts empty.

return function(H)
  local eq, ok = H.eq, H.ok
  local history = require("runtime-analysis.history")

  -- Nothing recorded yet: an empty list, not an error.
  do
    local dir = vim.fn.tempname()
    eq(#history.list({ dir = dir }), 0, "history.list: empty before anything is recorded")
  end

  -- Recording, and the newest-first order M.list promises.
  do
    local dir = vim.fn.tempname()
    history.record("GET", "https://api.example.com/a", 200, nil, { dir = dir })
    history.record("POST", "https://api.example.com/b", 404, nil, { dir = dir })

    local entries = history.list({ dir = dir })
    eq(#entries, 2, "history.record: two entries recorded")
    eq(entries[1].method, "POST", "history.list: newest first ...")
    eq(entries[1].url, "https://api.example.com/b", "history.list: ... same entry, url too")
    eq(entries[2].method, "GET", "history.list: ... oldest last")
    ok(entries[1].at ~= nil and entries[1].at > 0, "history.list: a real timestamp, not nil")
  end

  -- status vs. note: a real response sets status and leaves note nil; an
  -- errored/cancelled attempt is the opposite — never both at once.
  do
    local dir = vim.fn.tempname()
    history.record("GET", "https://api.example.com/ok", 200, nil, { dir = dir })
    history.record("GET", "https://api.example.com/down", nil, "connection refused", { dir = dir })
    history.record("GET", "https://api.example.com/cancelled", nil, "cancelled", { dir = dir })

    local entries = history.list({ dir = dir })
    -- newest first: cancelled, down, ok
    eq(entries[1].status, nil, "history.record: a cancelled entry has no status")
    eq(entries[1].note, "cancelled", "history.record: ... and does have a note")
    eq(entries[2].status, nil, "history.record: an errored entry has no status either")
    eq(
      entries[2].note,
      "connection refused",
      "history.record: ... with the real error text as its note"
    )
    eq(entries[3].status, 200, "history.record: a real response has a status")
    eq(entries[3].note, nil, "history.record: ... and no note — never both at once")
  end

  -- A note is only ever kept when status is nil, even if a caller passes
  -- both — status is the more informative of the two when both are known.
  do
    local dir = vim.fn.tempname()
    history.record("GET", "https://api.example.com/x", 200, "ignored note", { dir = dir })
    eq(
      history.list({ dir = dir })[1].note,
      nil,
      "history.record: note is dropped when status is present, not kept alongside it"
    )
  end

  -- Bounded cardinality: recording past the cap drops the oldest,
  -- keeps the newest — the same "size is a function of usage, not of how
  -- long ago it started" discipline telemetry's own argument fingerprinting
  -- already applies.
  do
    local dir = vim.fn.tempname()
    for i = 1, history.max_entries() + 5 do
      history.record("GET", ("https://api.example.com/%d"):format(i), 200, nil, { dir = dir })
    end
    local entries = history.list({ dir = dir })
    eq(#entries, history.max_entries(), "history.record: capped at max_entries(), not left to grow")
    eq(
      entries[1].url,
      ("https://api.example.com/%d"):format(history.max_entries() + 5),
      "history.record: the newest entry survives the cap"
    )
    eq(
      entries[history.max_entries()].url,
      "https://api.example.com/6",
      "history.record: the oldest 5 were dropped, not the newest"
    )
  end

  -- `opts.root`: a reader analyzing a different tree
  -- than cwd gets *that* tree's history, not whichever project Neovim
  -- happens to be sitting in — `M.record` itself stays cwd-only (recording
  -- is always "I just sent a request from here"), only `M.list`/`M.clear`
  -- take the override.
  do
    local dir = vim.fn.tempname()
    -- Recorded with no `root` — keys on cwd, same as every other test here.
    history.record("GET", "https://api.example.com/here", 200, nil, { dir = dir })

    eq(#history.list({ dir = dir }), 1, "history.list: cwd's own history, unaffected by root")
    eq(
      #history.list({ dir = dir, root = "/not/the/same/project/at/all" }),
      0,
      "history.list: a different root reads a genuinely different, empty history"
    )
  end

  -- Clearing.
  do
    local dir = vim.fn.tempname()
    history.record("GET", "https://api.example.com/a", 200, nil, { dir = dir })
    ok(
      #history.list({ dir = dir }) > 0,
      "history: sanity — something was recorded before clearing"
    )
    history.clear({ dir = dir })
    eq(#history.list({ dir = dir }), 0, "history.clear: empty afterward")
  end

  -- -------------------------------------------------------------------------
  -- ERR-11: a corrupt history file must not read back exactly like "nothing
  -- recorded yet" — `M.list` returns a distinct `err` alongside the (still
  -- empty) list, and `M.record`'s own load-modify-save cycle warns once
  -- via `vim.notify` instead of silently resetting the file with no trace
  -- anything went wrong (the original bytes are backed up to `.corrupt` by
  -- `lib.nvim.cache.disk` itself before either of these ever sees them).
  -- -------------------------------------------------------------------------
  do
    local dir = vim.fn.tempname()
    local path = history.data_path({ dir = dir })
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    local f = assert(io.open(path, "w"))
    f:write("{ not valid json")
    f:close()

    local entries, list_err = history.list({ dir = dir })
    eq(#entries, 0, "history.list: a corrupt file still yields an empty list")
    ok(list_err ~= nil, "history.list: ... but a distinct err is returned alongside it")

    ok(
      vim.fn.filereadable(path .. ".corrupt") == 1,
      "history.list: the original corrupt bytes were backed up, not lost"
    )
  end

  do
    local dir = vim.fn.tempname()
    local path = history.data_path({ dir = dir })
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    local f = assert(io.open(path, "w"))
    f:write("{ not valid json")
    f:close()

    local orig_vim_notify = vim.notify
    local calls = {}
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(msg, level)
      calls[#calls + 1] = { msg = msg, level = level }
    end

    history.record("GET", "https://api.example.com/after-corruption", 200, nil, { dir = dir })

    vim.notify = orig_vim_notify

    ok(#calls > 0, "history.record: a corrupt load warns via vim.notify")

    local entries = history.list({ dir = dir })
    eq(#entries, 1, "history.record: the new request is still recorded despite the corruption")
    eq(
      entries[1].url,
      "https://api.example.com/after-corruption",
      "history.record: ... with the right content"
    )
  end

  -- Secret query values: replaced by the placeholder, never cut off.
  do
    local R = history.REDACTED
    local r = history.redact_url
    eq(r("https://a.io/x?api_key=abc"), "https://a.io/x?api_key=" .. R, "redact: single key")
    eq(
      r("https://a.io/x?q=1&Token=abc&z=2"),
      "https://a.io/x?q=1&Token=" .. R .. "&z=2",
      "redact: case, middle position"
    )
    eq(
      r("https://a.io/x?a=1&access_token=s&sig=t"),
      "https://a.io/x?a=1&access_token=" .. R .. "&sig=" .. R,
      "redact: several keys"
    )
    eq(
      r("https://a.io/x?ap%69_key=abc"),
      "https://a.io/x?ap%69_key=" .. R,
      "redact: percent-encoded key"
    )
    eq(
      r("https://a.io/x?key=abc#frag"),
      "https://a.io/x?key=" .. R .. "#frag",
      "redact: plain fragment kept"
    )
    eq(
      r("https://a.io/x#access_token=abc&state=1"),
      "https://a.io/x#access_token=" .. R .. "&state=1",
      "redact: fragment params"
    )
    eq(
      r("https://a.io/x?api_key={{apiKey}}"),
      "https://a.io/x?api_key={{apiKey}}",
      "redact: {{var}} untouched"
    )
    eq(
      r("https://a.io/x?monkey=1&keys=2&key="),
      "https://a.io/x?monkey=1&keys=2&key=",
      "redact: other names / empty value untouched"
    )
    eq(
      r("https://a.io/x?a=1;token=2"),
      "https://a.io/x?a=1;token=" .. R,
      "redact: semicolon separator"
    )
    eq(
      r("https://a.io/#/route?token=2&x=1"),
      "https://a.io/#/route?token=" .. R .. "&x=1",
      "redact: query inside the fragment"
    )
    eq(
      r("https://u:pw@a.io:8080/x?q=1"),
      "https://u:" .. R .. "@a.io:8080/x?q=1",
      "redact: userinfo password"
    )
    eq(
      r("https://u:p%40w@a.io/"),
      "https://u:" .. R .. "@a.io/",
      "redact: userinfo password with encoded @"
    )
    eq(r("https://u:{{pw}}@a.io/"), "https://u:{{pw}}@a.io/", "redact: userinfo template untouched")
    for _, u in ipairs({
      "https://user@a.io/",
      "https://a.io:8080/p@q",
      "https://a.io/x?e=a@b.c",
      "https://a.io/x",
      "https://a.io/x/key/abc",
      "{{baseUrl}}/u/:id",
      "",
    }) do
      eq(r(u), u, "redact: no query stays byte-equal: " .. u)
    end

    local dir = vim.fn.tempname()
    history.record("GET", "https://a.io/x?password=hunter2&q=1", 200, nil, { dir = dir })
    eq(
      history.list({ dir = dir })[1].url,
      "https://a.io/x?password=" .. R .. "&q=1",
      "record: stores the redacted url"
    )
  end

  -- Option `history_secret_keys`: own list replaces the default; `{}` is off.
  -- Entries already on disk are cleaned on the next write.
  do
    local R = history.REDACTED
    local ra = require("runtime-analysis")
    local saved = ra.opts.history_secret_keys
    ra.opts.history_secret_keys = { "X-Sig" }
    eq(
      history.redact_url("https://a.io/?x-sig=1&token=2"),
      "https://a.io/?x-sig=" .. R .. "&token=2",
      "opts: own list replaces the default"
    )
    ra.opts.history_secret_keys = {}
    eq(
      history.redact_url("https://a.io/?token=2"),
      "https://a.io/?token=2",
      "opts: empty list switches redaction off"
    )

    local dir = vim.fn.tempname()
    history.record("GET", "https://a.io/?token=legacy", 200, nil, { dir = dir })
    ra.opts.history_secret_keys = saved
    history.record("GET", "https://a.io/ok", 200, nil, { dir = dir })
    eq(
      history.list({ dir = dir })[2].url,
      "https://a.io/?token=" .. R,
      "record: older entries are redacted on the next write"
    )
  end
end
