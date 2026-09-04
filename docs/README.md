# runtime-analysis.nvim documentation

What is here, and which question each page answers. [The README](../README.md)
is the short version of all of it.

## Using it

| Page | Answers |
| --- | --- |
| [COMMANDS.md](COMMANDS.md) | One compound verb, two flat aliases and a second compound one, argument by argument — the reference for everything you can ask for |
| [BINDINGS.md](BINDINGS.md) | Every keymap, user command and autocommand. Hand-maintained rather than generated, on the argument that the surface is small enough for that to stay true |
| [WORKFLOW.md](WORKFLOW.md) | The different question: not what each command reports, but which one answers which question about a running session |

## Why it is the way it is

| Page | Answers |
| --- | --- |
| [FEATURES/](FEATURES/README.md) | One page per area — the loaded-module view, request tracking, benchmarking, and the telemetry join — each pointing into the decision record for the reasoning |
| [FEATURE_LOG.md](FEATURE_LOG.md) | The decision record: what shipped and the trade-off behind it. Referenced by section from the feature pages, which is what makes it load-bearing rather than a changelog — a backlog item that ships is moved here in full instead of being struck through where it stood |
| [IDEAS.md](IDEAS.md) | Why an idea is cut the way it is, what it would cost, and what argues against it. Explicitly *not* a queue — what gets built next lives in one plan across all three repositories — and its "deliberately not" section is the part that keeps earning its place |

## Here, but not prose

**`install.json`** declares the external tools this plugin can use,
machine-readably, for `:Lib deps show runtime-analysis.nvim`. **`map/`** is the
generated module map — one of the two repositories in the collection that
actually ships it.
