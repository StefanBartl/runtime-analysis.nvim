-- TESTS/telemetry_html_spec.lua — runtime-analysis.telemetry.
-- renderers.html
--
-- A real telemetry instance, real calls, a real `t.report()` — the same
-- data `:RATelemetry open` would actually hand this renderer, not a hand-
-- built fixture that could drift from `RA.Telemetry.Report`'s real shape.

return function(H)
  local eq, ok = H.eq, H.ok
  local telemetry = require("runtime-analysis.telemetry")
  local html = require("runtime-analysis.telemetry.renderers.html")

  local seq = 0
  local function ns(name)
    seq = seq + 1
    return ("spec.html.%s.%d"):format(name, seq)
  end

  -- A real report, with real argument profiling, error fingerprints and
  -- call-tree data all present at once -- the busiest realistic shape.
  local function build_report()
    local mod = {
      fetch = function(id)
        if id == "bad" then
          error("boom")
        end
        return id
      end,
    }
    local t = telemetry.new({ namespace = ns("dashboard"), persist = false })
    t.wrap(mod, "m")
    t.start({ profile_args = true, errors = true, call_tree = true })

    local function caller_a()
      mod.fetch("1")
    end
    local function caller_b()
      mod.fetch("1")
    end
    caller_a()
    caller_a()
    caller_b()
    pcall(mod.fetch, "bad")

    local report = t.report()
    t.stop()
    return report
  end

  -- render: no error on a real, populated report; the essential content
  -- -- function key, real numbers, the embedded JSON data blob -- is all
  -- present in the output.
  do
    local report = build_report()
    local out = html.render({ report })

    ok(out:find("<!doctype html>", 1, true) ~= nil, "render: a real, complete HTML document")
    ok(out:find("m.fetch", 1, true) ~= nil, "render: the real function key appears")
    ok(
      out:find("window.__RA_TELEMETRY_ROWS__", 1, true) ~= nil,
      "render: the row data is embedded for the client-side script"
    )
    ok(out:find(report.namespace, 1, true) ~= nil, "render: the real namespace appears")
    ok(out:find("<style>", 1, true) ~= nil, "render: the CSS design system is embedded")
    ok(out:find("<script>", 1, true) ~= nil, "render: the sort/filter script is embedded")

    -- The embedded JSON itself decodes and carries the real numbers, not
    -- just plausible-looking text -- proves the data survived the
    -- Lua -> JSON -> string round trip intact.
    local blob = out:match("window%.__RA_TELEMETRY_ROWS__ = (%[.-%]);")
    assert(blob, "render: the row JSON blob is extractable from the page")
    local rows = vim.json.decode(blob)
    eq(#rows, 1, "render: one row for the one real function")
    eq(rows[1].calls, 4, "render: the real call count made it into the row data")
    eq(rows[1].errors, 1, "render: the real error count made it into the row data")
    ok(rows[1].top_arg ~= nil, "render: a top argument fingerprint is present")
    ok(rows[1].top_caller ~= nil, "render: a top caller fingerprint is present")

    -- The client-side script itself HTML-escapes every field that is
    -- real, untrusted text from the analyzed code before it ever reaches
    -- innerHTML -- an argument fingerprint IS built from a real argument
    -- value, so a string argument containing "<img onerror=...>" must
    -- render as that literal text, not be interpreted as markup. This
    -- can only be checked at the source level here (no JS engine in this
    -- test harness to actually run the script and inspect the real DOM),
    -- but it is a real regression guard: it fails the moment any of
    -- these five insertion points loses its escHtml() wrapper again.
    ok(out:find("function escHtml", 1, true) ~= nil, "render: the escHtml helper is defined")
    for _, field in ipairs({ "r.namespace", "r.key", "r.top_arg", "r.top_caller", "r.hint" }) do
      ok(
        out:find("escHtml(" .. field, 1, true) ~= nil,
        ("render: %s is passed through escHtml before reaching innerHTML"):format(field)
      )
    end
  end

  -- render: an empty report (no calls at all) still produces a complete,
  -- valid page -- an empty table client-side, not a Lua error server-side.
  do
    local t = telemetry.new({ namespace = ns("empty"), persist = false })
    t.wrap({ f = function() end }, "m")
    t.start()
    local report = t.report()
    t.stop()

    local out = html.render({ report })
    ok(
      out:find("<!doctype html>", 1, true) ~= nil,
      "render: still a complete document with 0 calls"
    )
    local blob = out:match("window%.__RA_TELEMETRY_ROWS__ = (%[.-%]);")
    local rows = vim.json.decode(blob)
    ok(rows ~= nil and vim.tbl_isempty(rows), "render: an empty rows array, not an error")
  end

  -- render: several namespaces combined into one page (the bare
  -- `:RATelemetry open` case) -- one row per (namespace, function), the
  -- real total across all of them in the header stats.
  do
    local mod1 = { f = function() end }
    local mod2 = { g = function() end }
    local t1 = telemetry.new({ namespace = ns("multi_a"), persist = false })
    local t2 = telemetry.new({ namespace = ns("multi_b"), persist = false })
    t1.wrap(mod1, "m")
    t2.wrap(mod2, "m")
    t1.start()
    t2.start()
    mod1.f()
    mod2.g()
    mod2.g()

    local reports = { t1.report(), t2.report() }
    t1.stop()
    t2.stop()

    local out = html.render(reports)
    local blob = out:match("window%.__RA_TELEMETRY_ROWS__ = (%[.-%]);")
    local rows = vim.json.decode(blob)
    eq(#rows, 2, "render: one row per namespace's own function")
    ok(
      out:find("2</b> namespace", 1, true) ~= nil,
      "render: the header states the real namespace count"
    )
  end

  -- render: a namespace containing a literal `</script>` cannot break out
  -- of the <script> block the row JSON sits inside -- the HTML parser
  -- only ever looks for the literal closing-tag bytes, so an unescaped
  -- occurrence inside the embedded JSON string would truncate the page's
  -- own script early and dump the rest as visible text. The `<\/script`
  -- escape is invisible to JSON parsing (decodes back to the identical
  -- string) but not to the HTML parser.
  do
    local adversarial_ns = ns('title"with</script>tag')
    local mod = { f = function() end }
    local t = telemetry.new({ namespace = adversarial_ns, persist = false })
    t.wrap(mod, "m")
    t.start()
    mod.f()
    local report = t.report()
    t.stop()

    local out = html.render({ report })
    ok(
      out:find("</script>tag", 1, true) == nil,
      "render: no literal </script> sequence anywhere in the page, even from an adversarial namespace"
    )
    ok(
      out:find("<\\/script>tag", 1, true) ~= nil,
      "render: it is present in its escaped, HTML-parser-safe form instead"
    )
    local blob = out:match("window%.__RA_TELEMETRY_ROWS__ = (%[.-%]);")
    assert(blob, "render: the JSON blob is still extractable with an adversarial namespace")
    local rows = vim.json.decode(blob)
    eq(
      rows[1].namespace,
      adversarial_ns,
      "render: the real, unescaped namespace round-trips through JSON intact"
    )
    eq(rows[1].calls, 1, "render: the real data survived despite the adversarial name")
  end
end
