# Configuration

Everything `require("runtime-analysis").setup(opts)` accepts. Defaults live in
[`lua/runtime-analysis/config/DEFAULTS.lua`](../lua/runtime-analysis/config/DEFAULTS.lua),
which is the single source of truth this page is written from.

```lua
require("runtime-analysis").setup({
  split = "vsplit",             -- default; "split" for a horizontal one
  request_filetype = "http",    -- default
  deps_popup = true,            -- default
  history_max_entries = 200,    -- default
  telemetry = { ... },          -- opt-in; absent by design
})
```

## Top-level keys

Five, and that is the whole list.

| Key | Default | What it decides |
| --- | --- | --- |
| `split` | `"vsplit"` | Where the response pane opens relative to the request buffer. `"split"` for a horizontal one. |
| `request_filetype` | `"http"` | Filetype set on a new `:RA request` buffer. `http` rather than a plugin-specific name, because VS Code's REST Client and IntelliJ's HTTP Client already claim it and this buffer's syntax matches theirs — so existing highlighting for either tool works here unmodified. |
| `deps_popup` | `true` | The one-time "which CLI tools does this plugin want, and why" popup on the first `setup()` after install. `false` disables it for this plugin specifically, in the spec itself — no `vim.g` needed. See [`installation.md`](installation.md). |
| `history_max_entries` | `200` | How many past sends `:RA history` keeps, per project. A ring: the file's size stays a function of how much the plugin is used, not of how long ago it was first started. |
| `telemetry` | **absent** | Auto-instrument every plugin as it loads. Absent means no auto-instrumentation at all, exactly as if `telemetry.auto()` were never called — a default table would switch it on for everyone who never asked. |

## A misspelled key gets one warning, not silence

`setup()` validates its keys *before* merging anything and names the closest
real one — `deps_popups` comes back as *unknown, did you mean "deps_popup"?*
Fail-open by design: it warns and continues, never blocks `setup()`.

The same check runs on `telemetry.new()` and on the lazy.nvim adapter's own
options, which is where it matters most, since those tables are deeper.

Without it a typo'd option vanishes into whatever the default already was,
with nothing anywhere saying the key was never read — which is the failure
this exists for, not tidiness.
[`config/validate.lua`](../lua/runtime-analysis/config/validate.lua) is the
implementation; the threshold below which a guess is withheld rather than
misleading is stated there.

## `telemetry` — the auto-instrumentation table

The one key with structure of its own. Three sub-keys, all optional:

| Sub-key | Shape | For |
| --- | --- | --- |
| `plugins` | `table<repo, opts>`, keyed by repo (`"StefanBartl/markdown.nvim"`) | plugins a plugin manager resolves. Only the lazy.nvim adapter is shipped |
| `extra` | a list of targets | anything a plugin manager does *not* resolve — chiefly your own config |
| `lib_nvim` | `{ profile_args?, timing?, persist?, dir? }` or `false` | lib.nvim's own aggregate, which wraps through `lib.strategies.telemetry_wrap` rather than `wrap_loaded()` |

### Instrumenting your own config (`extra`)

Your own config has no repo, no spec, and usually several unrelated root
prefixes rather than one `main` — yet it is often the most interesting Lua
tree in the session, and the only one whose dead code nobody else will ever
report on.

```lua
require("runtime-analysis").setup({
  telemetry = {
    extra = {
      {
        namespace = "nvim-config",
        -- your config's own top-level lua/ directories
        mains = { "config", "bindings", "plugins", "autocmds", "lsp" },
        profile_args = true,
      },
    },
  },
})
```

That is the whole setup. `nvim-config` then behaves as an ordinary namespace
everywhere: `:RATelemetry nvim-config`, `coverage`, `compare`, `snapshot`,
`export`, the HTML dashboard, and `:RATelemetry setup|full nvim-config`.

**It works without lazy.nvim.** `extra` resolves purely through
`package.loaded`; the lazy.nvim adapter covers `plugins` only.

**Wrapping is deferred to `VimEnter` by default, and that default matters.**
When `runtime-analysis.setup()` runs it is usually still *inside*
`lazy.setup()`, before your config's later phases (options, autocmds, LSP,
keymaps) have required anything — and `wrap_loaded()` only ever sees what is
already in `package.loaded`. Wrapping at that moment would produce a nearly
empty namespace. `wrap_at` overrides it per target:

| `wrap_at` | when |
| --- | --- |
| `"VimEnter"` | default — VimEnter + `vim.schedule`, once the UI is up |
| `"setup"` | immediately; only right for an already-loaded target |
| `"manual"` | never automatically; `:RATelemetry setup\|full <ns>` only |

Per-target options: `mains` (required), `namespace` (required), `deep`
(default **true** here, unlike a plugin's façade-first default),
`profile_args`, `timing`, `persist`, `dir`, `wrap_at`.

**The same blind spot every wrap has:** a module first required *after* the
wrap ran (a keymap handler pulled in on first press) stays unwrapped until
something re-wraps. `:RATelemetry setup <ns>` is that something, callable any
time — see [`commands.md`](commands.md).

### Per-instance telemetry options

`retention_days`, `flush_interval_ms`, `max_arg_values`, `persist`, `dir`,
`remind_after`, `report_file`, `report_style`, `info`,
`snapshot_retention` — these belong to a telemetry *instance*, not to
`setup()`, and are documented where they are implemented:
[`lua/runtime-analysis/telemetry/README.md`](../lua/runtime-analysis/telemetry/README.md).
They have no default here on purpose; the absence of the `telemetry` key is
what means "do not instrument".

## `runtime-analysis.startup` options

Stall detection is configured per call, not through `setup()` — it is a
measurement you start, not a mode the plugin runs in. See
[`FEATURES/STARTUP.md`](FEATURES/STARTUP.md#options).
