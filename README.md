# runtime-analysis.nvim

Runtime truth, paired with [documentation.nvim](https://github.com/StefanBartl/documentation.nvim)'s
static truth — see that plugin's `docs/ECOSYSTEM.md` for the full
architecture this pairing is part of. documentation.nvim knows what exists
and is documented; this plugin knows what actually happens when it runs.

## What's here today

The first feature (`ECOSYSTEM.md` step 5): an in-editor HTTP request
runner. No browser, no server, no CORS, no token — the cheap first version
that plan calls for specifically, because none of those problems exist for
a request Neovim itself sends via `curl`.

### Usage

```vim
:RARequest
```

Opens a new buffer, one request per buffer, in the same shape VS Code's
REST Client / IntelliJ's HTTP Client already use:

```http
POST https://api.example.com/users
Content-Type: application/json
Authorization: Bearer abc123

{"name": "Alice"}
```

`METHOD url` on the first non-blank line, `Name: value` headers, a blank
line, then an optional body — everything after the blank line, verbatim.

```vim
:RASend
```

Run from inside that buffer: parses it, sends it, and shows the response
(status, headers, body) in a persistent split beside it. The response pane
is reused across sends rather than opening a new split every time, and
sending a request never steals focus away from the buffer you're editing —
the whole point is edit, send, glance at the response, edit again.

### Setup

```lua
require("runtime-analysis").setup({
  split = "vsplit",           -- default; "split" for a horizontal one
  request_filetype = "http",  -- default
})
```

### Telemetry (step 7)

`runtime-analysis.telemetry` — opt-in call counting and usage statistics
for any Lua/Neovim plugin, moved here from lib.nvim. `:RATelemetry` is
registered by the same `setup()` call above; see
[`lua/runtime-analysis/telemetry/README.md`](lua/runtime-analysis/telemetry/README.md)
for the full API (`wrap`/`wrap_loaded`, persistence, Markdown/browser
reports, the `:RATelemetry` subcommands). lib.nvim itself keeps a thin
caller, `lib.strategies.telemetry_wrap`, for instrumenting its own
`require("lib")` aggregate specifically — everything else in this module is
generic.

### Integration with documentation.nvim (step 6)

`M.open_request(lines)` is this plugin's one public integration surface —
written against a small named interface from the start, per
`docs/ECOSYSTEM.md` §7's own stated rule, rather than another plugin
reaching into this one's internal files. documentation.nvim's `:DocBrowse`
Endpoints mode is the first consumer: pressing `gs` on a route it found by
static analysis calls `require("runtime-analysis").open_request({"METHOD
path", ""})` — a soft dependency (`pcall(require, "runtime-analysis")`),
absent with a clear message when this plugin is not installed.

Deliberately not an immediate send: a route's path (`/users/:id`) is
relative and may contain unfilled `:param`s — genuinely nothing
documentation.nvim's static analysis could send correctly on its own — so
the method and path are pre-filled and the reader completes the base URL
(and any params) before running `:RASend` themselves.

## What's not here yet

- **Async sending.** `:RASend` blocks until the response arrives — real,
  and fine for a request bounded in seconds, but a genuine limitation for
  a slow endpoint.
- **Request history.** Nothing is saved between sends yet.
- **Multiple requests per buffer** (`###`-separated, the way both sibling
  tools support). One request per buffer for now.
- **The static × runtime join** — `:DocBrowse`'s planned Mode 7 (a
  *different*, later mode than the Endpoints mode step 6 already added),
  joining documentation.nvim's static analysis against telemetry's counts —
  is a later step in `ECOSYSTEM.md`'s own sequencing, not this one.

## Dependencies

- Neovim 0.10+ (`vim.system`)
- [lib.nvim](https://github.com/StefanBartl/lib.nvim) — `lib.nvim.net.curl`'s
  `fetch_raw`/`fetch_raw_blocking` for the request runner (this plugin is
  the reason those exist: the HTTP status code and response headers were
  not previously exposed by that module at all), plus `cache.disk`, `git`,
  `ui.kit`, `usercmd`, `notify`, `autocmd` and `progress` for telemetry.
