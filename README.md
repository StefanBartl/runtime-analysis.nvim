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

## What's not here yet

- **Async sending.** `:RASend` blocks until the response arrives — real,
  and fine for a request bounded in seconds, but a genuine limitation for
  a slow endpoint.
- **Request history.** Nothing is saved between sends yet.
- **Multiple requests per buffer** (`###`-separated, the way both sibling
  tools support). One request per buffer for now.
- **The static × runtime join** — telemetry, and `:DocBrowse`'s planned
  Mode 7 — is a later step in `ECOSYSTEM.md`'s own sequencing, not this
  one.

## Dependencies

- Neovim 0.10+ (`vim.system`)
- [lib.nvim](https://github.com/StefanBartl/lib.nvim) — specifically
  `lib.nvim.net.curl`'s `fetch_raw`/`fetch_raw_blocking`, which this plugin
  is the reason those exist: the HTTP status code and response headers
  were not previously exposed by that module at all.
