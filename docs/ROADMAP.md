# runtime-analysis.nvim — the outlook

**What this plugin is, in one sentence:** it measures what actually happens
at runtime — and is thereby the counter-check to a static analyzer, which can
only see what is written in the text.

This file was empty until 2026-08-20. What was missing here is the direction;
the derivation of every single idea has always been in
[`IDEAS.md`](IDEAS.md), and what was built is in
[`FEATURES/FINISHED.md`](FEATURES/FINISHED.md).

> **The queue lives elsewhere.** What gets built next — here *and* in
> `documentation.nvim` and `docmap-desktop` — has been in **one** plan since
> 2026-08-20:
> [`docmap-desktop/docs/PLAN.md`](https://github.com/StefanBartl/docmap-desktop/blob/main/docs/PLAN.md).

## Where this is going

**Static analysis's blind spot is the job.** A function that is bound as a
callback value, or reached through dynamic dispatch, has no call site naming
it — to a parser it does not exist, and the telemetry sees it run. Every
useful intersection with `documentation.nvim` follows from that one
asymmetry: churn × call count separates "refactor" from "delete", coverage ×
telemetry yields the queue of *hot and untested*, and the hover says how
often a function was really entered over the last seven days.

**From counting to measuring.** Call counts are the beginning; timings and
shapes are the road to a profiler. For API traffic the line is drawn in
advance and it is not negotiable: **metadata and shapes, never payloads** —
because the recordings get committed.

**Two browser stages exist, and neither is used up.** A third pipeline will
not be built. `report_style = "preview-tab"` is the browser-free stage and
takes the binary-download pause out of the default path.

## Three limits that are not up for negotiation

They are in [`IDEAS.md`](IDEAS.md) §7 with the full rationale; they are here
because they explain why some things are *not* coming.

- **`documentation.nvim` must never depend hard on this plugin.** A static
  analyzer that does not run without a runtime plugin has lost exactly the
  property that makes it useful in CI.
- **Runtime data never belongs in the committed artifact.** It breaks the
  byte comparison at generation time, and it is personal, quickly stale usage
  data at commit time.
- **Runtime evidence must never *raise* the severity of a check.** A warning
  that appears on one machine and not on another is worse than no warning. As
  a *suppression*, by contrast, it is right, and that is how it is used.

And one that gets proposed often: **sharing telemetry between machines**, so
that "cold on this machine" is no longer confused with "unused". The right
answer to that is honest wording in the render, not an aggregation service.
