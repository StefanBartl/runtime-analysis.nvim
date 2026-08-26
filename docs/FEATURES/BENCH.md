# Benchmark comparisons

`runtime-analysis.bench` — timed comparisons between candidate functions:
"which of these two implementations is actually faster, on this machine,
right now". A bounded, explicit, few-seconds measurement a caller asks
for by name, not something installed or left running — the property that
lets it exist without reopening `docs/ROADMAP.md` §3.5's "not a general
profiler" rejection.

## Direct calls, not telemetry-wrapped

- **Module:** `bench.lua` (`compare`), measured by `scripts/bench_overhead.lua`
- **Why:** counting-only overhead is ~10-15 ns/call, argument profiling ~600-700 ns — enough to swamp the comparison

The roadmap idea this closes assumed reusing `runtime-analysis.telemetry`'s
own wrap/count machinery would be free. It measurably isn't —
`scripts/bench_overhead.lua` puts counting-only overhead at ~10-15ns per
call and argument profiling at ~600-700ns, real costs that would swamp
the very comparison a benchmark exists to make. `bench.compare` calls
every candidate directly, unwrapped, the same discipline
`scripts/bench_overhead.lua`'s own baseline row already uses.

```lua
local bench = require("runtime-analysis.bench")

local result = bench.compare({
  { name = "impl_a", fn = impl_a },
  { name = "impl_b", fn = impl_b },
}, { iterations = 10000 })

print(result.fastest)
for _, line in ipairs(bench.lines(result)) do
  print(line)
end
```

Each candidate gets an equal, explicit warmup pass (`opts.warmup`, default
`min(100, iterations)`) before the timed run — so comparison *order*
doesn't bias the result the way it would if only the first candidate paid
a cold-cache cost the others didn't.

## Compare-now only, on purpose

No persistence, no named runs, no `:RA bench` command — confirmed with
the user as later scope, not because it would be hard, but because it
hasn't actually been asked for. `M.compare` returns a plain table; what a
caller does with it is up to the caller. Pure Lua API, unlike
`:RA inspect`/`:RA loaded snapshot` — a benchmark candidate is a real Lua
function value, and there is no command-line shape for "type the two
closures you want compared".

- **Module:** `bench.lua` (`M.compare`, `M.lines`)
- **Docs:** decision record in [`../FEATURE_LOG.md`](../FEATURE_LOG.md) (§3.6).
