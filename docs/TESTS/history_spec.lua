-- docs/TESTS/history_spec.lua — runtime-analysis.history
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

  -- Bounded cardinality: recording past M.MAX_ENTRIES drops the oldest,
  -- keeps the newest — the same "size is a function of usage, not of how
  -- long ago it started" discipline telemetry's own argument fingerprinting
  -- already applies.
  do
    local dir = vim.fn.tempname()
    for i = 1, history.MAX_ENTRIES + 5 do
      history.record("GET", ("https://api.example.com/%d"):format(i), 200, nil, { dir = dir })
    end
    local entries = history.list({ dir = dir })
    eq(#entries, history.MAX_ENTRIES, "history.record: capped at MAX_ENTRIES, not left to grow")
    eq(
      entries[1].url,
      ("https://api.example.com/%d"):format(history.MAX_ENTRIES + 5),
      "history.record: the newest entry survives the cap"
    )
    eq(
      entries[history.MAX_ENTRIES].url,
      "https://api.example.com/6",
      "history.record: the oldest 5 were dropped, not the newest"
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
end
