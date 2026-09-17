-- TESTS/startup_profile_spec.lua — runtime-analysis.startup.profile
--
-- Almost everything here runs against a `--startuptime` log held as a
-- literal. That is the point of the module's split: the part that owns the
-- log format (`parse`) and the part that owns the statistics (`aggregate`)
-- are both pure, and a spec that spawned five editors to check a median
-- would be slow, flaky on a loaded CI runner, and still would not prove the
-- median right.
--
-- The exception is the last two blocks, which start Neovim three times
-- between them. They are there because the driver once folded a start that
-- exited non-zero into the median as if it had succeeded, and let a second
-- profile run against the first — neither of which any amount of testing
-- pure functions would have caught. A bug in the process driver needs a
-- test in the process driver.

return function(H)
  local eq, ok = H.eq, H.ok
  local profile = require("runtime-analysis.startup.profile")

  -- A real `nvim --startuptime` log, trimmed. Both line shapes are here:
  -- three numbers for a sourced script, two for an event.
  local LOG = {
    "",
    "times in msec",
    " clock   self+sourced   self:  sourced script",
    " clock   elapsed:              other lines",
    "",
    "000.009  000.009: --- NVIM STARTING ---",
    "000.201  000.192: locale set",
    "006.120  000.406  000.406: sourcing /usr/share/nvim/runtime/ftplugin.vim",
    "010.500  002.000  001.500: sourcing /home/u/.local/share/nvim/lazy/plenary/plugin/p.vim",
    "012.000  000.500: opening buffers",
  }

  -- parse: both shapes, the right number out of each, nothing from the banner
  do
    local entries, total = profile.parse(LOG)
    eq(#entries, 5, "parse: five measured lines, the banner contributes none")
    eq(total, 12, "parse: total is the largest clock value in the log")

    local by_name = {}
    for _, e in ipairs(entries) do
      by_name[e.name] = e
    end

    local ftplugin = by_name["/usr/share/nvim/runtime/ftplugin.vim"]
    ok(ftplugin, "parse: the `sourcing ` prefix is stripped, leaving the path")
    eq(ftplugin.kind, "sourced", "parse: a three-number line is a sourced script")
    eq(ftplugin.ms, 0.406, "parse: a sourced line contributes its SELF time")

    local plenary = by_name["/home/u/.local/share/nvim/lazy/plenary/plugin/p.vim"]
    eq(plenary.ms, 1.5, "parse: self, not self+sourced — 1.500, never 2.000")

    local locale = by_name["locale set"]
    eq(locale.kind, "event", "parse: a two-number line is an event")
    eq(locale.ms, 0.192, "parse: an event contributes its elapsed time")
  end

  -- parse: a log with nothing parseable yields nothing, rather than raising
  do
    local entries, total = profile.parse({ "times in msec", "", "garbage" })
    eq(#entries, 0, "parse: an unparseable log is empty, not an error")
    eq(total, 0, "parse: and its total is zero")
  end

  -- aggregate: the median is the middle run, not the mean
  do
    local function run(ms)
      return { entries = { { name = "a.vim", kind = "sourced", ms = ms } }, total_ms = ms }
    end
    -- 1, 2, 90: the mean is 31, the median is 2. An outlier run is exactly
    -- what medians are here to survive.
    local report = profile.aggregate({ run(1), run(2), run(90) })
    eq(#report.entries, 1, "aggregate: one name, one row")
    local e = report.entries[1]
    eq(e.median_ms, 2, "aggregate: odd count takes the middle value")
    eq(e.mean_ms, 31, "aggregate: the mean is kept alongside it")
    eq(e.min_ms, 1, "aggregate: min")
    eq(e.max_ms, 90, "aggregate: max")
    eq(e.runs, 3, "aggregate: appeared in every run")
    ok(e.stddev_ms > 40, "aggregate: the spread says loudly that this is scatter")
    eq(report.total_ms, 2, "aggregate: the startup total is a median too")
  end

  -- aggregate: an even count averages the two middle values
  do
    local function run(ms)
      return { entries = { { name = "a.vim", kind = "sourced", ms = ms } }, total_ms = 0 }
    end
    local report = profile.aggregate({ run(2), run(4), run(6), run(10) })
    eq(report.entries[1].median_ms, 5, "aggregate: even count averages the middle pair")
  end

  -- aggregate: a file that loads in only some runs says so
  do
    local report = profile.aggregate({
      { entries = { { name = "a.vim", kind = "sourced", ms = 1 } }, total_ms = 10 },
      {
        entries = {
          { name = "a.vim", kind = "sourced", ms = 3 },
          { name = "b.vim", kind = "sourced", ms = 5 },
        },
        total_ms = 10,
      },
    })
    eq(report.runs, 2, "aggregate: two runs")
    local by_name = {}
    for _, e in ipairs(report.entries) do
      by_name[e.name] = e
    end
    eq(by_name["a.vim"].runs, 2, "aggregate: a.vim loaded in both")
    eq(by_name["b.vim"].runs, 1, "aggregate: b.vim only in one — not averaged over two")
    eq(by_name["b.vim"].median_ms, 5, "aggregate: and its median is its single sample")
  end

  -- aggregate: the same name twice in one run is one sample, summed
  do
    local report = profile.aggregate({
      {
        entries = {
          { name = "a.vim", kind = "sourced", ms = 2 },
          { name = "a.vim", kind = "sourced", ms = 3 },
        },
        total_ms = 10,
      },
    })
    eq(report.entries[1].runs, 1, "aggregate: sourced twice in one run is still one run")
    eq(report.entries[1].median_ms, 5, "aggregate: and its cost is the sum of both")
  end

  -- aggregate: a name and an event with the same text stay apart
  do
    local report = profile.aggregate({
      {
        entries = {
          { name = "same", kind = "sourced", ms = 1 },
          { name = "same", kind = "event", ms = 7 },
        },
        total_ms = 10,
      },
    })
    eq(#report.entries, 2, "aggregate: kind is part of the key, so the two do not merge")
  end

  -- aggregate: sorting and truncation
  do
    local entries = {}
    for i = 1, 40 do
      entries[i] = { name = ("f%02d.vim"):format(i), kind = "sourced", ms = i }
    end
    local report = profile.aggregate({ { entries = entries, total_ms = 100 } })
    eq(#report.entries, 25, "aggregate: `top` defaults to 25")
    eq(report.entries[1].name, "f40.vim", "aggregate: sorted by median, worst first")

    local all = profile.aggregate({ { entries = entries, total_ms = 100 } }, { top = 0 })
    eq(#all.entries, 40, "aggregate: top = 0 keeps everything")

    local by_name = profile.aggregate({ { entries = entries, total_ms = 100 } }, { sort = "name" })
    eq(by_name.entries[1].name, "f01.vim", "aggregate: sort = name")
  end

  -- lines / markdown: a heading, one row per entry, and a trailer
  do
    local entries, total = profile.parse(LOG)
    local report = profile.aggregate({ { entries = entries, total_ms = total } })
    local lines = profile.lines(report)
    ok(lines[1]:match("WHAT"), "lines: opens with a heading row")
    ok(lines[1]:match("MEDIAN"), "lines: and names the headline column")
    -- heading + rows + blank + total + the two "what SPREAD means" lines.
    -- The `nvim <argv>` line is NOT among them: `aggregate` was called
    -- directly here, so no binary was ever named, and a line reading
    -- `----  ` would be noise pretending to be provenance.
    eq(#lines, #report.entries + 5, "lines: heading, rows, blank, total, trailer")
    ok(
      table.concat(lines, "\n"):match("12%.0 ms median startup"),
      "lines: the trailer reports the whole startup, not the sum of the rows"
    )

    local md = profile.markdown(report)
    eq(md[1], "# startup profile", "markdown: opens with the heading")
    ok(table.concat(md, "\n"):match("| `locale set` |"), "markdown: one table row per entry")
  end

  -- path_at: addressed by row, sourced rows only, and only if still readable
  do
    local real = vim.fn.tempname() .. ".lua"
    local f = assert(io.open(real, "w"))
    f:write("-- measured\n")
    f:close()

    local report = profile.aggregate({
      {
        entries = {
          { name = real, kind = "sourced", ms = 9 },
          { name = "opening buffers", kind = "event", ms = 5 },
          { name = "/no/such/file.vim", kind = "sourced", ms = 1 },
        },
        total_ms = 20,
      },
    })

    eq(profile.path_at(report, 1), nil, "path_at: row 1 is the heading, not an entry")
    eq(profile.path_at(report, 2), real, "path_at: row 2 is the first entry's own path")
    eq(profile.path_at(report, 3), nil, "path_at: an event row has no file")
    eq(profile.path_at(report, 4), nil, "path_at: a path that no longer exists is not offered")
    eq(profile.path_at(report, 99), nil, "path_at: past the end is nil, not an error")

    os.remove(real)
  end

  -- lines: a multi-byte name still lines up with the heading
  do
    -- `%-44s` pads by BYTES, so this row used to come out four cells short of
    -- the heading and take every column after it along with it. The name is
    -- also longer than the column, so this covers the truncation too.
    local name = "/home/müller/ÄÖÜ-ein-sehr-langes-verzeichnis/plugin/ä.lua"
    local report = profile.aggregate({
      { entries = { { name = name, kind = "event", ms = 1 } }, total_ms = 1 },
    })
    local lines = profile.lines(report)
    eq(
      vim.fn.strdisplaywidth(lines[2]),
      vim.fn.strdisplaywidth(lines[1]),
      "lines: a multi-byte row is as wide as the heading, in display cells"
    )
    ok(
      vim.fn.strchars(lines[2]) > 0 and not lines[2]:find("99189"),
      "lines: and is cut on a character boundary, not mid-sequence"
    )
  end

  -- run: an unusable binary is reported, and reported without starting anything
  do
    local done, err_seen = false, nil
    profile.run({ nvim = "definitely-not-a-real-nvim-binary", runs = 1 }, function(report, err)
      done, err_seen = true, err
      eq(report, nil, "run: no report when the binary cannot be run")
    end)
    ok(done, "run: the callback fires synchronously for this case")
    ok(err_seen and err_seen:match("not executable"), "run: and says why")
    eq(profile.is_running(), false, "run: a refused run does not leave the guard set")
  end

  -- run: a start that exits non-zero is a failure, not a sample
  do
    -- `+cquit` runs before `+qall!` and exits non-zero AFTER --startuptime has
    -- already written most of its log, which is exactly the shape that used to
    -- sail through as a valid run and land in the median.
    local done, rep, err_seen = false, nil, nil
    profile.run({ runs = 1, clean = true, args = { "+cquit" } }, function(report, err)
      rep, err_seen, done = report, err, true
    end)
    ok(
      vim.wait(60000, function()
        return done
      end, 50),
      "run: the aborted run reported back within the timeout"
    )
    eq(rep, nil, "run: the only run failed, so there is no report")
    ok(err_seen and err_seen:match("failed"), "run: and the error says every run failed")
    eq(profile.is_running(), false, "run: the guard is clear again afterwards")
  end

  -- run: a second run is refused while one is in flight
  do
    local first_done, second_err = false, nil
    profile.run({ runs = 1, clean = true }, function()
      first_done = true
    end)
    ok(profile.is_running(), "run: the guard is set while a run is in flight")
    profile.run({ runs = 1, clean = true }, function(report, err)
      second_err = err
      eq(report, nil, "run: the refused second call gets no report")
    end)
    ok(
      second_err and second_err:match("already running"),
      "run: two profiles at once would compete for CPU, so the second is refused"
    )
    ok(
      vim.wait(60000, function()
        return first_done
      end, 50),
      "run: the first run still completes"
    )
    eq(profile.is_running(), false, "run: and clears the guard when it does")
  end
end
