# Stall detection — `runtime-analysis.startup`

**What it is.** `:RA startup` answers "why did Neovim just freeze for half a
second", including during startup — where the usual tools cannot help.

**Modules:** [`startup/init.lua`](../../lua/runtime-analysis/startup/init.lua) (stalls),
[`startup/profile.lua`](../../lua/runtime-analysis/startup/profile.lua) (the profiler) ·
**Commands:** `:RA startup start|watch|report|probe|profile`
([`commands.md`](../commands.md)) · **Lua API:** [`api.md`](../api.md)

## Why not `--startuptime` or `:profile`

`nvim --startuptime` stops writing at the first screen redraw. The freeze
people actually complain about tends to arrive *after* that, so the log ends
before the interesting part.

Which is why `:RA startup profile` exists alongside this one and runs
`--startuptime` itself, N times over — see below. `--startuptime` is not
wrong, it is *early and file-shaped*, and that is a different blind spot from
this page's, not a worse one.

`:profile` instruments Vimscript and Lua calls, and is therefore blind to
libuv callbacks — which is exactly where filesystem work, subprocesses and LSP
message handling live. A `vim.fn.system(...):wait()` inside an autocommand
does not show up as anything.

## How it works

A libuv timer measures **its own lateness**. If it asks to run every 20ms and
comes back 900ms late, the loop was blocked for 900ms — no matter what blocked
it: Lua, C, a subprocess, the OS. Nothing needs instrumenting, and nothing can
hide from it.

That alone only gives you a symptom, so every event that could plausibly
explain a block is stamped on the same clock: each lazy.nvim plugin load,
`VimEnter`, `VeryLazy`, `LspAttach` and LSP progress. A `STALL` line covers
`[at - blocked, at]`, so the events listed directly above it are the suspects.

Plugin lines carry lazy's own load time **and why it loaded**, which is usually
the part that cracks a case:

```
  +  0.68 s  event   VeryLazy
  +  0.89 s  ***** STALL  blocked    209 ms  (from +0.68 s)
  +  1.03 s  plugin  sandbox.nvim (65 ms)  <- VeryLazy
  +  1.08 s  plugin  gopath.nvim (62 ms)  <- VeryLazy
  +  2.50 s  plugin  telescope.nvim (74 ms)  <- require 'telescope' from init.lua
```

`<- VeryLazy` means the spec asked for it. `<- require '<mod>' from <file>`
means some other file pulled the plugin in and defeated its own lazy-loading —
and only the second kind is a bug you can fix. A plugin declaring
`cmd = "Telescope"` and still loading at startup looks perfectly innocent in
`:Lazy`; this is where it becomes visible.

## Measuring a freeze you can reproduce

```vim
:RA startup start     " watches for 12s, then reports
:RA startup watch     " watches until you ask for the report
:RA startup report    " stop and show the timeline
```

The report arrives as a notification and is written to `ra-startup.log` in the
current directory.

## Measuring startup itself

The timer has to be ticking before your config is sourced, which a lazily
loaded plugin cannot arrange for itself. Use the bootstrap probe:

```sh
nvim --cmd "luafile /path/to/runtime-analysis.nvim/probe/startup.lua" file.lua
```

`:RA startup probe` prints that line with the path filled in and yanks it, so
there is nothing to retype.

The probe puts the plugin on `package.path` from its own location — no
runtimepath, no plugin manager, no configuration involved — and hands over to
the module. Options can be passed ahead of it:

```sh
nvim --cmd "lua vim.g.ra_startup = { duration_ms = 30000, stall_ms = 200 }" \
     --cmd "luafile /path/to/runtime-analysis.nvim/probe/startup.lua" file.lua
```

## Options

Passed to `startup.start(opts)`, or through `vim.g.ra_startup` for the probe.
Not `setup()` keys — this is a measurement you start, not a mode the plugin
runs in.

| Option | Default | Meaning |
| --- | --- | --- |
| `interval_ms` | `20` | How often the timer asks to run. |
| `stall_ms` | `80` | Only lateness at or above this counts as a stall. |
| `duration_ms` | `12000` | Auto-report after this long; `0` measures until stopped. |
| `log_file` | `"ra-startup.log"` | Written on report; `""` writes none. |
| `notify` | `true` | Show the report as a notification. |

## Reading the numbers

Two things worth knowing before drawing conclusions from a single run:

- **Startup timing scatters.** Runs of an identical config vary by hundreds of
  milliseconds, mostly from filesystem cache and, on Windows, the AV filter
  driver. Compare medians of three runs, not single numbers — which is what
  [`:RA startup profile`](#ra-startup-profile--what-each-file-costs-over-enough-runs-to-mean-it)
  below does for you.
- **A stall is not always the plugin named above it.** The line is the leading
  suspect, not a verdict — a load time of 40ms under a 300ms block means
  something else contributed too.

## `:RA startup profile` — what each file costs, over enough runs to mean it

The section above tells you to compare medians of three runs. This is the
command that does it.

```vim
:RA startup profile      " five runs, averaged
:RA startup profile 10   " ten, for a number you intend to act on
```

Neovim is started `N` times under `--startuptime`, sequentially (two at once
would compete for CPU and disk and inflate each other), every log is parsed,
and the per-file costs are folded into one table:

```
  WHAT                                           MEDIAN     MEAN   SPREAD     RUNS
  lazy.nvim/lua/lazy/init.lua                      8.41     9.02     1.13      5/5
  telescope.nvim/plugin/telescope.lua              6.20     6.35     0.31      5/5
  locale set                                       4.84     5.54     5.09      5/5
  ...

  ---- 187.7 ms median startup over 5 run(s)
```

**MEDIAN is the headline, SPREAD is the disclaimer.** A row whose spread
rivals its median has not told you anything: that is the filesystem cache and,
on Windows, the AV filter driver, not a plugin worth fixing. Measure again
with more runs before acting on it.

**RUNS is `n/N`** — how many of the runs that file was sourced in at all. A
`3/5` means it loaded conditionally, and its median is over those three, not
diluted by two zeroes it never measured.

**`gf` on a row opens the file it measured.** `r` is not wired here on
purpose: a refresh would silently re-run five editors behind a key nobody
expects to take ten seconds. Run the command again instead.

### The three startup measurements, and why there are three

| | Sees | Blind to |
| --- | --- | --- |
| `:RA startup profile` | every file `source`d, whatever sourced it, from the very first millisecond | anything after the first screen redraw; module-level cost inside one file |
| `:RA startup` | the main loop blocking, whatever blocked it — including libuv callbacks nothing can instrument | what any single file cost |
| `:RATelemetry startup` | inside a plugin: which *module* the cost sits in, as a require waterfall | everything already in `package.loaded` when it armed — Neovim's own runtime, lazy.nvim, every earlier plugin |

The blind spots do not overlap, which is the whole reason all three exist. The
profiler is the one that sees the earliest and knows the least; the telemetry
waterfall is the one that sees the least and knows the most.

**This does mean the plugin now runs the tool it defines itself against.**
`--startuptime` was never wrong — it is early and file-shaped, and it stops at
the first redraw. What it could not do alone was be *believed*, because one
log is scatter. Five are an argument.

### Two honest limits

- **A measured start is not your start.** It is spawned with a pipe rather
  than a terminal, so a line like `reading stdin` shows up that an interactive
  launch would not have. It costs about a millisecond and it is in every run
  equally, so it moves no comparison — but it is there.
- **It profiles the config it finds.** Pass `clean = true` through the Lua API
  to measure `nvim --clean` instead, which is the baseline worth knowing
  before blaming a plugin for what Neovim costs on its own.

## Not the same thing as `:RATelemetry startup`

Two different measurements with adjacent names, deliberately kept apart:

- **`:RA startup`** (this page) measures the *main loop's* lateness. It needs
  no instrumentation and sees a block whatever caused it, including one that
  never enters Lua at all.
- **`:RATelemetry startup`** attributes a plugin's load cost to the *module*
  it actually sits in, as a waterfall. It wraps the global `require` and times
  every cache miss, so it sees inside a plugin — but only from the moment it
  was armed (`telemetry.startup.autostart()`, from a lazy.nvim `init` hook).
