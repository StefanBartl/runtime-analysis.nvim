---@module 'runtime-analysis.telemetry.renderers.html'
--- A purpose-built HTML dashboard — docs/ROADMAP.md §4.4. The Markdown
--- report answers "what happened" in prose; this answers the same
--- question sortable and filterable, the way documentation.nvim's own
--- Analysis tab already does for static findings.
---
--- **Not `documentation.nvim`'s renderer, stolen wholesale.** That module
--- (`core/render/html.lua`) is ~4,500 lines, of which ~3,850 are one
--- embedded JavaScript single-page app tightly coupled to its own IR
--- (module nodes, require/call edges, findings) — genuinely reusing it
--- for telemetry's own, completely different data shape (call counts,
--- argument/error/caller fingerprints, timing) would mean either a large
--- extraction project in that repository first, or bolting foreign data
--- onto machinery built for a tree. Decided, 2026-08-04: reuse the
--- *design* — the same CSS custom properties (colors, spacing, type
--- scale, light/dark via `prefers-color-scheme` and `data-theme`), the
--- same visual language (`.bd` badges, `.sec` section labels, `.toolbar`
--- search input) — in a new, small, self-contained page written for this
--- data, not that one. A few hundred lines here versus a few thousand
--- there, and no dependency from this plugin's own report onto
--- documentation.nvim's internal (and IR-specific) module.
---
--- One flat table, one row per (namespace, function) pair — `calls`,
--- `errors`, `mean_ms` when timing is on, the single most-called argument
--- fingerprint and its share, the single most-common immediate caller and
--- its share. Click a row for the full breakdown (every kept fingerprint,
--- the memoization hint, error fingerprints, callers) — the same `└`/`✗`/
--- `←`/`ⓘ` symbols `report.lines`'s own terminal rendering already uses,
--- so a reader moving between `:RATelemetry` and this page recognizes the
--- same vocabulary. Sortable by clicking a column header; filterable by a
--- plain substring over namespace + function key, matching the "no OR,
--- narrowing exists to make the list shorter" rule `:DocBrowse`'s own `f`
--- filter states for the identical reason.

local M = {}

-- HTML-escape text destined for server-rendered markup. Not the same `esc()`
-- the comment near the embedded `JS` string below refers to — that one is a
-- client-side JavaScript function baked into that string, not Lua.
local esc = require("lib.lua.strings.encoding").html_escape

-- Same design tokens as documentation.nvim's own `core/render/html.lua` —
-- see this module's own doc-comment for why they are copied rather than
-- required from there (a fork of static values, not of behavior; nothing
-- here re-executes documentation.nvim's own code).
local CSS = [[
:root{
  --bg:#fbfbfa; --panel:#fff; --ink:#1a1a19; --muted:#6b6b68; --line:#e4e4e1;
  --accent:#3b6ea8; --accent-soft:#eaf1f9;
  --error:#b3261e; --warn:#8a5a00;
  --mono:ui-monospace,SFMono-Regular,"SF Mono",Menlo,Consolas,monospace;
}
@media (prefers-color-scheme:dark){
  :root{
    --bg:#16171a; --panel:#1d1f23; --ink:#e6e6e3; --muted:#9a9a95; --line:#2e3136;
    --accent:#7aa9dd; --accent-soft:#22303f;
    --error:#f2837b; --warn:#e0b060;
  }
}
:root[data-theme="light"]{
  --bg:#fbfbfa; --panel:#fff; --ink:#1a1a19; --muted:#6b6b68; --line:#e4e4e1;
  --accent:#3b6ea8; --accent-soft:#eaf1f9; --error:#b3261e; --warn:#8a5a00;
}
:root[data-theme="dark"]{
  --bg:#16171a; --panel:#1d1f23; --ink:#e6e6e3; --muted:#9a9a95; --line:#2e3136;
  --accent:#7aa9dd; --accent-soft:#22303f; --error:#f2837b; --warn:#e0b060;
}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);
  font:15px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif}
header{padding:20px 24px 14px;border-bottom:1px solid var(--line);
  display:flex;flex-wrap:wrap;gap:14px;align-items:baseline}
h1{margin:0;font-size:20px;font-weight:650;letter-spacing:-.01em}
h1 .sub{color:var(--muted);font-weight:400;font-size:14px;margin-left:8px}
.stats{margin-left:auto;display:flex;gap:14px;font-size:12.5px;color:var(--muted);flex-wrap:wrap}
.stats b{color:var(--ink);font-weight:600}
.toolbar{padding:12px 24px;display:flex;gap:10px;align-items:center;flex-wrap:wrap;
  border-bottom:1px solid var(--line)}
#q{flex:1;min-width:200px;max-width:440px;padding:7px 11px;border:1px solid var(--line);
  border-radius:7px;background:var(--panel);color:var(--ink);font-size:14px}
#q:focus{outline:2px solid var(--accent-soft);border-color:var(--accent)}
table{width:100%;border-collapse:collapse;font-size:13.5px}
th{text-align:left;padding:8px 14px;border-bottom:1px solid var(--line);color:var(--muted);
  font-size:11.5px;text-transform:uppercase;letter-spacing:.04em;cursor:pointer;user-select:none;
  white-space:nowrap}
th:hover{color:var(--ink)}
th.sorted{color:var(--accent)}
td{padding:7px 14px;border-bottom:1px solid var(--line);vertical-align:top}
tr.fnrow{cursor:pointer}
tr.fnrow:hover td{background:var(--accent-soft)}
.k{font-family:var(--mono);font-size:12.5px}
.ns{color:var(--muted);font-size:11.5px}
.num{text-align:right;font-variant-numeric:tabular-nums}
.bd{font-size:9.5px;letter-spacing:.04em;text-transform:uppercase;padding:1px 5px;
  border-radius:4px;border:1px solid var(--line);color:var(--muted);white-space:nowrap}
.bd.err{color:var(--error);border-color:var(--error)}
.bd.hint{color:var(--accent);border-color:var(--accent)}
.fp{font-family:var(--mono);font-size:12px;color:var(--muted)}
.detail{padding:10px 14px 16px 32px;background:var(--panel);display:none}
.detail.open{display:table-cell}
.detail .sec{font-size:10.5px;text-transform:uppercase;letter-spacing:.06em;color:var(--muted);
  margin:10px 0 4px;font-weight:600}
.detail .sec:first-child{margin-top:0}
.detail ul{list-style:none;margin:0;padding:0}
.detail li{font-family:var(--mono);font-size:12.5px;padding:2px 0;color:var(--ink)}
.detail .hint{color:var(--accent);font-family:inherit;font-size:13px}
.empty{padding:40px 24px;color:var(--muted);font-size:14px;text-align:center}
]]

---@internal
---@param n number?
---@return string
local function num(n)
  if not n then
    return ""
  end
  local s = tostring(math.floor(n + 0.5))
  return (s:reverse():gsub("(%d%d%d)", "%1 "):reverse():gsub("^%s+", ""))
end

---@internal
---@param fingerprints { fingerprint: string, count: integer, share: number }[]?
---@param symbol string
---@return string
local function fp_list_html(fingerprints, symbol)
  if not fingerprints or #fingerprints == 0 then
    return ""
  end
  local items = {}
  for _, fp in ipairs(fingerprints) do
    items[#items + 1] = ("<li>%s %3.0f%%  %s</li>"):format(
      symbol,
      fp.share * 100,
      esc(fp.fingerprint)
    )
  end
  return table.concat(items, "")
end

---Turn one report's entries into flat row objects, JSON-ready — the exact
---data a browser-side `<script>` needs, computed here rather than
---client-side so the JS stays render-only.
---@internal
---@param report RA.Telemetry.Report
---@return table[]
local function rows_for(report)
  local rows = {}
  for _, e in ipairs(report.entries) do
    local top_arg = e.args and e.args[1]
    local top_caller = e.callers and e.callers[1]
    rows[#rows + 1] = {
      namespace = report.namespace,
      key = e.key,
      calls = e.calls,
      errors = e.errors,
      mean_ms = e.mean_ms,
      top_arg = top_arg and ("%3.0f%%  %s"):format(top_arg.share * 100, top_arg.fingerprint) or nil,
      top_caller = top_caller
          and ("%3.0f%%  %s"):format(top_caller.share * 100, top_caller.fingerprint)
        or nil,
      hint = e.hint,
      args_html = fp_list_html(e.args, "└"),
      error_fp_html = fp_list_html(e.error_fp, "✗"),
      callers_html = fp_list_html(e.callers, "←"),
    }
  end
  return rows
end

local JS = [[
(function(){
  var rows = window.__RA_TELEMETRY_ROWS__;
  var tbody = document.getElementById("tbody");
  var q = document.getElementById("q");
  var ths = document.querySelectorAll("th[data-sort]");
  var sortKey = "calls", sortDir = -1;

  function fmtNum(n){
    if (n === null || n === undefined) return "";
    var s = String(Math.round(n));
    return s.replace(/\B(?=(\d{3})+(?!\d))/g, " ");
  }

  // `namespace`/`key`/`top_arg`/`top_caller`/`hint` are real text from the
  // analyzed code -- a function name, an argument fingerprint (which is
  // built from an argument's own value), a memoization hint. None of that
  // is trusted HTML, and an argument value that happens to contain `<`/
  // `>`/`&` must render as that literal text, not be interpreted as
  // markup. `args_html`/`error_fp_html`/`callers_html` are the one
  // exception: already HTML-escaped server-side (see this file's own
  // `esc()`), so re-escaping them here would double-escape instead.
  function escHtml(s){
    if (s === null || s === undefined) return "";
    return String(s)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  function render(){
    var needle = q.value.trim().toLowerCase();
    var filtered = rows.filter(function(r){
      if (!needle) return true;
      return (r.namespace + "#" + r.key).toLowerCase().indexOf(needle) !== -1;
    });
    filtered.sort(function(a, b){
      var av = a[sortKey], bv = b[sortKey];
      if (av === undefined || av === null) av = -Infinity;
      if (bv === undefined || bv === null) bv = -Infinity;
      if (typeof av === "string") return sortDir * av.localeCompare(bv);
      return sortDir * (av - bv);
    });

    if (filtered.length === 0){
      tbody.innerHTML = "";
      document.getElementById("empty").style.display = "block";
      return;
    }
    document.getElementById("empty").style.display = "none";

    var html = [];
    filtered.forEach(function(r, i){
      html.push('<tr class="fnrow" data-i="' + i + '">');
      html.push('<td><span class="ns">' + escHtml(r.namespace) + '</span><br><span class="k">' + escHtml(r.key) + '</span></td>');
      html.push('<td class="num">' + fmtNum(r.calls) + '</td>');
      html.push('<td class="num">' + (r.errors > 0 ? '<span class="bd err">' + fmtNum(r.errors) + '</span>' : '') + '</td>');
      html.push('<td class="num">' + (r.mean_ms ? r.mean_ms.toFixed(2) + ' ms' : '') + '</td>');
      html.push('<td class="fp">' + escHtml(r.top_arg || '') + (r.hint ? ' <span class="bd hint">hint</span>' : '') + '</td>');
      html.push('<td class="fp">' + escHtml(r.top_caller || '') + '</td>');
      html.push('</tr>');
      html.push('<tr class="detailrow" data-i="' + i + '" style="display:none"><td colspan="6" class="detail">' + detailHtml(r) + '</td></tr>');
    });
    tbody.innerHTML = html.join("");

    document.querySelectorAll("tr.fnrow").forEach(function(tr){
      tr.addEventListener("click", function(){
        var i = tr.getAttribute("data-i");
        var detail = document.querySelector('tr.detailrow[data-i="' + i + '"] .detail');
        detail.classList.toggle("open");
      });
    });
  }

  function detailHtml(r){
    var out = [];
    if (r.args_html) out.push('<div class="sec">arguments</div><ul>' + r.args_html + '</ul>');
    if (r.hint) out.push('<div class="hint">ⓘ ' + escHtml(r.hint) + '</div>');
    if (r.error_fp_html) out.push('<div class="sec">error fingerprints</div><ul>' + r.error_fp_html + '</ul>');
    if (r.callers_html) out.push('<div class="sec">callers</div><ul>' + r.callers_html + '</ul>');
    if (out.length === 0) out.push('<span style="color:var(--muted)">no further detail collected</span>');
    return out.join("");
  }

  ths.forEach(function(th){
    th.addEventListener("click", function(){
      var key = th.getAttribute("data-sort");
      if (sortKey === key) {
        sortDir = -sortDir;
      } else {
        sortKey = key;
        sortDir = -1;
      }
      ths.forEach(function(t){ t.classList.remove("sorted"); });
      th.classList.add("sorted");
      render();
    });
  });
  q.addEventListener("input", render);

  render();
})();
]]

---Render `reports` (one or more, most-recently-flushed data) into a
---self-contained HTML string — no CDN, no build step, safe to open
---straight from disk with `file://`.
---@param reports RA.Telemetry.Report[]
---@return string
function M.render(reports)
  local all_rows = {}
  local total_calls, total_wrapped = 0, 0
  for _, report in ipairs(reports) do
    for _, row in ipairs(rows_for(report)) do
      all_rows[#all_rows + 1] = row
    end
    total_calls = total_calls + report.total_calls
    total_wrapped = total_wrapped + report.wrapped
  end

  local rows_json = require("lib.lua.json").encode(all_rows)
  if not rows_json then
    rows_json = "[]"
  end
  -- A namespace or function key containing a literal `</script>` (however
  -- unlikely) would otherwise close the tag this JSON sits inside early —
  -- the HTML parser does not know this text is a JSON string, only that
  -- it saw the closing-tag bytes. `<\/script` is valid JSON (an escaped,
  -- meaningless-but-legal `\/`) and decodes back to the identical string,
  -- so this is invisible to `vim.json.decode` on the client side.
  rows_json = rows_json:gsub("</script", "<\\/script")

  local title = #reports == 1 and reports[1].namespace or "all namespaces"

  return table.concat({
    "<!doctype html><html><head><meta charset='utf-8'>",
    "<title>runtime-analysis.telemetry — " .. esc(title) .. "</title>",
    "<style>" .. CSS .. "</style></head><body>",
    "<header><h1>runtime-analysis.telemetry<span class='sub'>" .. esc(title) .. "</span></h1>",
    ("<div class='stats'><span><b>%s</b> namespace(s)</span><span><b>%s</b> wrapped</span><span><b>%s</b> calls</span></div>"):format(
      #reports,
      num(total_wrapped),
      num(total_calls)
    ),
    "</header>",
    "<div class='toolbar'><input id='q' type='search' placeholder='Filter namespace or function…' autocomplete='off'></div>",
    "<table><thead><tr>",
    "<th data-sort='key'>Function</th>",
    "<th data-sort='calls' class='sorted'>Calls</th>",
    "<th data-sort='errors'>Errors</th>",
    "<th data-sort='mean_ms'>Mean</th>",
    "<th data-sort='top_arg'>Top argument</th>",
    "<th data-sort='top_caller'>Top caller</th>",
    "</tr></thead><tbody id='tbody'></tbody></table>",
    "<div id='empty' class='empty' style='display:none'>no rows match this filter</div>",
    "<script>window.__RA_TELEMETRY_ROWS__ = " .. rows_json .. ";</script>",
    "<script>" .. JS .. "</script>",
    "</body></html>",
  }, "\n")
end

return M
