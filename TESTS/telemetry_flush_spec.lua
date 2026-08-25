-- TESTS/telemetry_flush_spec.lua — writing without stopping.
--
-- Three questions a reader asks in this order, and the answers are the
-- reason this file exists rather than a paragraph in the README:
--
--   1. Are my counts on disk while the recording is still running?
--   2. If I quit Neovim and come back, do they add up or start over?
--   3. Can I force the write at a moment of my choosing?
--
-- (1) and (2) were already true and untested at this level: the periodic
-- flush and the merge-on-write in `store` each had their own coverage, but
-- nothing asserted the property those two exist to produce. (3) is
-- `:RATelemetry flush`, and `inst.flush()` under it.
--
-- Real files under a temp `dir`, never the user's cache: these specs assert
-- *what is on disk*, so an in-memory double would assert nothing.

return function(H)
  local eq, ok = H.eq, H.ok

  local telemetry = require("runtime-analysis.telemetry")
  local store = require("runtime-analysis.telemetry.store")

  ---A private cache directory per case, so nothing here can see, merge with
  ---or clobber another case's counts — or the reader's own.
  ---@return string
  local function tmpdir()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    return dir
  end

  ---Total calls recorded for `key`, read back out of the file itself.
  ---@param path string
  ---@param key string
  ---@return integer
  local function calls_on_disk(path, key)
    local f = io.open(path, "r")
    if not f then
      return -1
    end
    local body = f:read("*a")
    f:close()
    local okd, decoded = pcall(vim.json.decode, body)
    if not okd or type(decoded) ~= "table" then
      return -1
    end
    local data = decoded.data or decoded
    local fn = (data.functions or {})[key]
    return fn and (fn.calls or 0) or 0
  end

  -- ---------------------------------------------------------------------
  -- `store.data_path` names the file `store.save` actually writes.
  --
  -- The path rule is duplicated from `lib.nvim.cache.disk`, which keeps its
  -- own construction private. A duplicated rule is a rule that drifts, so
  -- this asserts the two agree rather than trusting that they do.
  -- ---------------------------------------------------------------------
  do
    local dir = tmpdir()
    local opts = { dir = dir }
    local path = store.data_path("probe.nvim", opts)

    eq(vim.fn.filereadable(path), 0, "data_path: nothing there before the first save")
    ok(store.save("probe.nvim", store.empty(), opts), "data_path: the save itself succeeded")
    eq(vim.fn.filereadable(path), 1, "data_path: names the file that save() created")
  end

  -- A namespace that would escape the cache directory is sanitized in the
  -- path too, not only in the write — otherwise the reported location and
  -- the real one would disagree for exactly the namespace where that
  -- matters most.
  --
  -- What actually has to hold is that no *separator* survives: `sanitize`
  -- keeps dots (a namespace is `markdown.nvim`), so the result of
  -- `"../../evil"` still reads `_.._evil` — which cannot traverse anywhere,
  -- because the slashes are what traversal is made of. Asserted as "the file
  -- sits directly in the telemetry directory", which is the property, rather
  -- than "the string contains no dots", which was the first guess and is
  -- merely a symptom of it.
  do
    local dir = tmpdir()
    local path = store.data_path("../../evil", { dir = dir })
    local prefix = dir .. "/telemetry/"
    eq(path:sub(1, #prefix), prefix, "data_path: a hostile namespace stays under the cache dir")
    eq(
      path:sub(#prefix + 1):find("[/]"),
      nil,
      "data_path: ...with no separator left in the file name itself"
    )
    ok(path:find("evil", 1, true) ~= nil, "data_path: ...and the name is still recognizable")
  end

  -- ---------------------------------------------------------------------
  -- Question 1: counts reach the disk while the run is still going.
  -- ---------------------------------------------------------------------
  do
    local dir = tmpdir()
    local mod = {
      hello = function()
        return 1
      end,
    }
    local inst = telemetry.new({
      namespace = "live.nvim",
      dir = dir,
      persist = true,
      -- Short so the spec does not sit for a minute. The default is 60s;
      -- what is under test is that the timer writes at all, not its period.
      flush_interval_ms = 120,
    })
    inst.wrap(mod)
    inst.start()
    mod.hello()
    mod.hello()
    mod.hello()

    local path = inst.data_path()
    vim.wait(1500, function()
      return calls_on_disk(path, "hello") == 3
    end, 50)

    eq(calls_on_disk(path, "hello"), 3, "live: the periodic flush wrote while running")
    ok(inst.is_running(), "live: ...and the instance is still recording")
    inst.stop()
  end

  -- ---------------------------------------------------------------------
  -- Question 2: a second session adds to the first, it does not replace it.
  --
  -- Two instances over one directory is what two Neovim processes are, as
  -- far as this file is concerned: the merge happens in `store`, against
  -- what is on disk, not against anything shared in memory.
  -- ---------------------------------------------------------------------
  do
    local dir = tmpdir()

    local function session(n)
      local mod = {
        hello = function()
          return n
        end,
      }
      local inst = telemetry.new({
        namespace = "restart.nvim",
        dir = dir,
        persist = true,
        flush_interval_ms = 0,
      })
      inst.wrap(mod)
      inst.start()
      for _ = 1, n do
        mod.hello()
      end
      inst.stop()
      return inst
    end

    local first = session(3)
    eq(calls_on_disk(first.data_path(), "hello"), 3, "restart: the first session's counts")

    local second = session(2)
    eq(
      calls_on_disk(second.data_path(), "hello"),
      5,
      "restart: the second session added to them rather than replacing them"
    )
  end

  -- ---------------------------------------------------------------------
  -- Question 3: flush on demand, and the recording survives it.
  --
  -- `flush_interval_ms = 0` switches the timer off entirely, so nothing but
  -- the explicit call can be what put the file there.
  -- ---------------------------------------------------------------------
  do
    local dir = tmpdir()
    local mod = {
      hello = function()
        return 1
      end,
    }
    local inst = telemetry.new({
      namespace = "manual.nvim",
      dir = dir,
      persist = true,
      flush_interval_ms = 0,
    })
    inst.wrap(mod)
    inst.start()
    mod.hello()

    local path = inst.data_path()
    eq(vim.fn.filereadable(path), 0, "flush: no timer, so nothing is written on its own")

    ok(inst.flush(), "flush: the explicit write succeeded")
    eq(calls_on_disk(path, "hello"), 1, "flush: ...and the call is in the file")
    ok(inst.is_running(), "flush: recording continues — this is not a stop")

    -- And it keeps counting into the same file afterwards, which is the
    -- whole point: a flush is a checkpoint, not an ending.
    mod.hello()
    ok(inst.flush(), "flush: a second write")
    eq(calls_on_disk(path, "hello"), 2, "flush: the checkpoint moved forward")
    inst.stop()
  end

  -- ---------------------------------------------------------------------
  -- The command surface knows the subcommand.
  --
  -- Asserted against the completion list rather than by running `:RATelemetry
  -- flush`, which would need a live instance in the global registry and
  -- would leave one behind. What can go wrong here is a handler added
  -- without its name — the key nobody can discover.
  -- ---------------------------------------------------------------------
  do
    local command = require("runtime-analysis.telemetry.command")
    eq(vim.tbl_contains(command.SUBCOMMANDS, "flush"), true, "command: `flush` is completable")
  end
end
