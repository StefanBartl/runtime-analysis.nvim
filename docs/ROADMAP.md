# runtime-analysis.nvim — roadmap

## Deliberately not: a general profiler

Neovim has `:profile`, and LuaJIT has its own profiler. This module's whole
premise is that it is *installed*, cheap and left running for a week — a
different instrument from one you switch on for thirty seconds to find a
hot loop. Competing with them would cost the property that makes this
useful. **Revisit if:** never, realistically. The right move if someone
needs a real profiler is to point at the real profiler.


