# runtime-analysis.nvim — module map

> **Generated** by `documentation`. Do not edit by hand — run `:DocMap`
> (or `nvim --headless -l scripts/gen_map.lua`) to regenerate.

**3 modules** · 3 namespaces · 32 helper files

The [interactive map](index.html) has filtering, full descriptions and
source links; this page is the version the code host renders directly.


## Namespaces

```mermaid
flowchart LR
  nlua["runtime-analysis.nvim"]
  nlua_runtime_analysis["runtime-analysisbr/smallruntime-analysis.nvim: runtime truth,…/small"]
  nlua_runtime_analysis_bindings["bindings"]
  nlua_runtime_analysis_config["configbr/smallConfiguration entry point — re-exports…/small"]
  nlua_runtime_analysis_telemetry["telemetrybr/smallOpt-in call counting and usage statistics…/small"]
  nlua --> nlua_runtime_analysis
  nlua_runtime_analysis --> nlua_runtime_analysis_bindings
  nlua_runtime_analysis --> nlua_runtime_analysis_config
  nlua_runtime_analysis --> nlua_runtime_analysis_telemetry
```


## Dependencies

Which parts of the tree require which, rolled up to the second level.
The [interactive map](index.html)'s **Deps** view has this per module,
in both directions, with load-time and lazy requires told apart.

```mermaid
flowchart LR
  nlua_runtime_analysis_assertions_lua["runtime-analysis.assertions"]
  nlua_runtime_analysis_bindings["bindings"]
  nlua_runtime_analysis_curl_lua["runtime-analysis.curl"]
  nlua_runtime_analysis_env_lua["runtime-analysis.env"]
  nlua_runtime_analysis_graphql_lua["runtime-analysis.graphql"]
  nlua_runtime_analysis_health_lua["runtime-analysis.health"]
  nlua_runtime_analysis_history_lua["runtime-analysis.history"]
  nlua_runtime_analysis_inspect_lua["runtime-analysis.inspect"]
  nlua_runtime_analysis_loaded_lua["runtime-analysis.loaded"]
  nlua_runtime_analysis_multipart_lua["runtime-analysis.multipart"]
  nlua_runtime_analysis_parse_lua["runtime-analysis.parse"]
  nlua_runtime_analysis_provenance_lua["runtime-analysis.provenance"]
  nlua_runtime_analysis_runner_lua["runtime-analysis.runner"]
  nlua_runtime_analysis_telemetry["runtime-analysis.telemetry"]
  nlua_runtime_analysis_usage_lua["runtime-analysis.usage"]
  nlua_runtime_analysis_view_lua["runtime-analysis.view"]
  nlua_runtime_analysis_bindings --> nlua_runtime_analysis_assertions_lua
  nlua_runtime_analysis_bindings --> nlua_runtime_analysis_curl_lua
  nlua_runtime_analysis_bindings --> nlua_runtime_analysis_env_lua
  nlua_runtime_analysis_bindings --> nlua_runtime_analysis_graphql_lua
  nlua_runtime_analysis_bindings --> nlua_runtime_analysis_history_lua
  nlua_runtime_analysis_bindings --> nlua_runtime_analysis_inspect_lua
  nlua_runtime_analysis_bindings --> nlua_runtime_analysis_loaded_lua
  nlua_runtime_analysis_bindings --> nlua_runtime_analysis_multipart_lua
  nlua_runtime_analysis_bindings --> nlua_runtime_analysis_parse_lua
  nlua_runtime_analysis_bindings --> nlua_runtime_analysis_provenance_lua
  nlua_runtime_analysis_bindings --> nlua_runtime_analysis_runner_lua
  nlua_runtime_analysis_bindings --> nlua_runtime_analysis_usage_lua
  nlua_runtime_analysis_bindings --> nlua_runtime_analysis_view_lua
  nlua_runtime_analysis_curl_lua --> nlua_runtime_analysis_multipart_lua
  nlua_runtime_analysis_health_lua --> nlua_runtime_analysis_env_lua
  nlua_runtime_analysis_health_lua --> nlua_runtime_analysis_history_lua
  nlua_runtime_analysis_health_lua --> nlua_runtime_analysis_telemetry
  nlua_runtime_analysis_health_lua --> nlua_runtime_analysis_usage_lua
  nlua_runtime_analysis_provenance_lua --> nlua_runtime_analysis_telemetry
  nlua_runtime_analysis_usage_lua --> nlua_runtime_analysis_telemetry
```


## Modules

| Module | Description | Fns | Docs |
|---|---|---|---|
| `runtime-analysis` | runtime-analysis.nvim: runtime truth, paired with documentation.nvim's static truth — see that plugin's `docs/ECOSYSTEM.md` for the full split. | 2 | [src](../../lua/runtime-analysis/init.lua) |
| &nbsp;&nbsp;`bindings` |  |  |  |
| &nbsp;&nbsp;`runtime-analysis.config` | Configuration entry point — re-exports the defaults in [`DEFAULTS.lua`](DEFAULTS.lua). |  | [src](../../lua/runtime-analysis/config/init.lua) |
| &nbsp;&nbsp;`runtime-analysis.telemetry` | Opt-in call counting and usage statistics for any Lua/Neovim plugin that points an instance at its own modules. | 28 | [README](../../lua/runtime-analysis/telemetry/README.md) · [src](../../lua/runtime-analysis/telemetry/init.lua) |
| &nbsp;&nbsp;&nbsp;&nbsp;`renderers` |  |  |  |

## Drift

0 errors · 0 warnings · 5 info

No errors or warnings.


<details>
<summary>5 informational findings</summary>


| Check | Message |
|---|---|
| `missing-readme` | lua/runtime-analysis has no README.md |
| `missing-readme` | lua/runtime-analysis/config has no README.md |
| `unreferenced-module` | runtime-analysis is required by no other file in the tree |
| `unreferenced-module` | runtime-analysis.bench is required by no other file in the tree |
| `unreferenced-module` | runtime-analysis.health is required by no other file in the tree |

</details>
