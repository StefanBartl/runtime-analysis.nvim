# Requests

The HTTP request runner: `:RA request`/`:RA send` and the pieces that turn
"send a request" into "keep a real API collection working."

## `# @expect` smoke tests

A `# @expect status 200` comment anywhere in a request block turns an
ordinary `:RA send` into a checked assertion — silent on a match, a real
quickfix entry (never auto-opened) on a mismatch or a transport failure.
Deliberately narrow: one directive, one thing it checks, not a general
assertion language a `.http` file would need its own parser generation to
extend safely.

- **Module:** `assertions.lua` (`M.extract`, `M.strip`)
- **Docs:** [`docs/commands.md`](../commands.md) "`:RA send`" section.

## GraphQL body shorthand

`X-Request-Type: GraphQL` (consumed, never actually sent) marks a
request's body as query text, optionally followed by a blank line and a
JSON variables object — `:RA send` builds the real `{"query": ...,
"variables": {...}}` payload before curl ever sees it, the same
convention VS Code's REST Client already uses, matched deliberately rather
than invented.

- **Module:** `graphql.lua` (`M.is_graphql`, `M.resolve`)
- **Docs:** [`docs/commands.md`](../commands.md) "GraphQL and multipart
  request bodies" section.

## Multipart/form-data with real local files

A `< ./relative/path` line as a part's own content means "read this local
file's real bytes," resolved relative to the request buffer's own
directory. Turns a multipart upload from something requiring a separate
script into a request buffer like any other.

- **Module:** `multipart.lua` (`M.is_multipart`, `M.resolve`,
  `M.to_curl_flags`)
- **Docs:** [`docs/commands.md`](../commands.md) "GraphQL and multipart
  request bodies" section.

## Environment-scoped variables

`{{baseUrl}}/users/:id` resolves against whichever environment `:RA env
<name>` selected, read from two per-project JSON files —
`http-client.env.json` (commit-safe) and `http-client.private.env.json`
(gitignored, where a real token belongs). Resolution happens exactly once,
right before a request reaches curl; request history and the "sending…"
placeholder both keep the literal `{{token}}`, never the resolved value —
the same reason `:RA export`ing a request never bakes a secret in either.

- **Module:** `env.lua` (`M.resolve`, `M.list_names`, `M.set_current`)
- **Usercmds:** `:RA env [name]` (see
  [BINDINGS.md](../BINDINGS.md#user-commands))
- **Docs:** [`docs/commands.md`](../commands.md) "`:RA env`" section.

## Request history, request-only

Every send is recorded — method, url, status, timestamp, per project —
deliberately without headers or body on either side: a header is very
often where the real secret actually lives, and a response can be large
and contain secrets of its own. `:RA history` opens a picker to reopen one
as a fresh request buffer; `:RA history clear` empties the current
project's history.

- **Module:** `history.lua` (`M.record`, `M.list`, `M.clear`)
- **Usercmds:** `:RA history [clear]` (see
  [BINDINGS.md](../BINDINGS.md#user-commands))
- **Docs:** [`docs/commands.md`](../commands.md) "`:RA history`" section.
