# runtime-analysis.nvim — module map

> **Generated** by `documentation`. Do not edit by hand — run `:DocMap`
> (or `nvim --headless -l scripts/gen_map.lua`) to regenerate.

**3 modules** · 2 namespaces · 35 helper files

The [interactive map](index.html) has filtering, full descriptions and
source links; this page is the version the code host renders directly.


## Namespaces

```mermaid
flowchart LR
  nlua_runtime_analysis["runtime-analysis.nvim"]
  nlua_runtime_analysis_bindings["bindings"]
  nlua_runtime_analysis_config["configbr/smallConfiguration entry point — re-exports…/small"]
  nlua_runtime_analysis_telemetry["telemetrybr/smallOpt-in call counting and usage statistics…/small"]
  nlua_runtime_analysis_telemetry_renderers["renderers"]
  nlua_runtime_analysis --> nlua_runtime_analysis_bindings
  nlua_runtime_analysis --> nlua_runtime_analysis_config
  nlua_runtime_analysis --> nlua_runtime_analysis_telemetry
  nlua_runtime_analysis_telemetry --> nlua_runtime_analysis_telemetry_renderers
```


## Dependencies

Which parts of the tree require which, rolled up to the second level.
The [interactive map](index.html)'s **Deps** view has this per module,
in both directions, with load-time and lazy requires told apart.

```mermaid
flowchart LR
  nlua_runtime_analysis_config_validate_lua["runtime-analysis.config.validate"]
  nlua_runtime_analysis_telemetry_command_lua["runtime-analysis.telemetry.command"]
  nlua_runtime_analysis_telemetry_config_lua["runtime-analysis.telemetry.config"]
  nlua_runtime_analysis_telemetry_cost_vs_use_lua["runtime-analysis.telemetry.cost_vs_use"]
  nlua_runtime_analysis_telemetry_fingerprint_lua["runtime-analysis.telemetry.fingerprint"]
  nlua_runtime_analysis_telemetry_lazy_lua["runtime-analysis.telemetry.lazy"]
  nlua_runtime_analysis_telemetry_registry_lua["runtime-analysis.telemetry.registry"]
  nlua_runtime_analysis_telemetry_renderers["renderers"]
  nlua_runtime_analysis_telemetry_report_lua["runtime-analysis.telemetry.report"]
  nlua_runtime_analysis_telemetry_report_file_lua["runtime-analysis.telemetry.report_file"]
  nlua_runtime_analysis_telemetry_report_style_lua["runtime-analysis.telemetry.report_style"]
  nlua_runtime_analysis_telemetry_setup_all_lua["runtime-analysis.telemetry.setup_all"]
  nlua_runtime_analysis_telemetry_startup_lua["runtime-analysis.telemetry.startup"]
  nlua_runtime_analysis_telemetry_store_lua["runtime-analysis.telemetry.store"]
  nlua_runtime_analysis_telemetry_command_lua --> nlua_runtime_analysis_telemetry_config_lua
  nlua_runtime_analysis_telemetry_command_lua --> nlua_runtime_analysis_telemetry_cost_vs_use_lua
  nlua_runtime_analysis_telemetry_command_lua --> nlua_runtime_analysis_telemetry_lazy_lua
  nlua_runtime_analysis_telemetry_command_lua --> nlua_runtime_analysis_telemetry_renderers
  nlua_runtime_analysis_telemetry_command_lua --> nlua_runtime_analysis_telemetry_report_lua
  nlua_runtime_analysis_telemetry_command_lua --> nlua_runtime_analysis_telemetry_report_file_lua
  nlua_runtime_analysis_telemetry_command_lua --> nlua_runtime_analysis_telemetry_report_style_lua
  nlua_runtime_analysis_telemetry_command_lua --> nlua_runtime_analysis_telemetry_setup_all_lua
  nlua_runtime_analysis_telemetry_command_lua --> nlua_runtime_analysis_telemetry_startup_lua
  nlua_runtime_analysis_telemetry_lazy_lua --> nlua_runtime_analysis_config_validate_lua
  nlua_runtime_analysis_telemetry_registry_lua --> nlua_runtime_analysis_telemetry_fingerprint_lua
  nlua_runtime_analysis_telemetry_renderers --> nlua_runtime_analysis_telemetry_report_file_lua
  nlua_runtime_analysis_telemetry_report_lua --> nlua_runtime_analysis_telemetry_store_lua
  nlua_runtime_analysis_telemetry_report_file_lua --> nlua_runtime_analysis_telemetry_store_lua
  nlua_runtime_analysis_telemetry_report_style_lua --> nlua_runtime_analysis_telemetry_renderers
  nlua_runtime_analysis_telemetry_setup_all_lua --> nlua_runtime_analysis_telemetry_lazy_lua
  nlua_runtime_analysis_telemetry_setup_all_lua --> nlua_runtime_analysis_telemetry_report_file_lua
  nlua_runtime_analysis_telemetry_setup_all_lua --> nlua_runtime_analysis_telemetry_store_lua
```


## Modules

| Module | Description | Fns | Docs |
|---|---|---|---|
| `bindings` |  |  |  |
| `runtime-analysis.config` | Configuration entry point — re-exports the defaults in [`DEFAULTS.lua`](../../lua/runtime-analysis/config/DEFAULTS.lua). |  | [src](../../lua/runtime-analysis/config/init.lua) |
| `runtime-analysis.telemetry` | Opt-in call counting and usage statistics for any Lua/Neovim plugin that points an instance at its own modules. | 28 | [README](../../lua/runtime-analysis/telemetry/README.md) · [src](../../lua/runtime-analysis/telemetry/init.lua) |
| &nbsp;&nbsp;`renderers` |  |  |  |

## Drift

0 errors · 0 warnings · 4 info

No errors or warnings.


<details>
<summary>4 informational findings</summary>


| Check | Message |
|---|---|
| `missing-readme` | lua/runtime-analysis has no README.md |
| `missing-readme` | lua/runtime-analysis/config has no README.md |
| `unreferenced-module` | runtime-analysis.bench is required by no other file in the tree |
| `unreferenced-module` | runtime-analysis.health is required by no other file in the tree |

</details>
