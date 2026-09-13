# Quickstart

Open a request buffer:

```vim
:RA request
```

One request per buffer, in the same shape VS Code's REST Client and IntelliJ's
HTTP Client already use:

```http
POST https://api.example.com/users
Content-Type: application/json
Authorization: Bearer abc123

{"name": "Alice"}
```

`:RA send` from inside it parses the buffer, sends it, and shows status,
headers and body in a split beside it — non-blocking, focus stays where you are
typing. That is the whole loop: edit, send, glance, edit again.

The other three areas answer rather than run:

```vim
:RA loaded                 " what package.loaded actually contains right now
:RA startup                " what blocked the main loop, and for how long
:RATelemetry               " what has run since instrumentation went live
:RA inspect <module>       " walk a live module table
:RA provenance vim.notify  " who wrapped this function
```

Verify your setup any time with:

```vim
:checkhealth runtime-analysis
```

See [commands.md](commands.md) for every command and argument, and
[FEATURES/README.md](FEATURES/README.md) for the reasoning behind each area.
