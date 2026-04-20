# World Building Bake Roadmap

This file documents the completed building-bake work on branch `54-world-map-caching-and-data`.

This roadmap is explicit on purpose:
- It only states behavior that exists in code or was measured in a proof run.
- If something is still a future idea, it is written as deferred, not implied.

## Confirmed Goal

Static building output should be baked once and loaded at runtime from per-chunk artifacts.
Unchanged buildings should not remesh every time the player returns.
Dirty chunks should be rebaked locally, not force nearby chunks to rebuild.

## Confirmed Implementation

- `world_map_generator/world_map_generator_ui.gd` bakes building snapshots after world save.
- `addons/tests/town_stall_test_harness.gd` bakes the same way for automated proof runs.
- `world_building_system/building_bake_service.gd` creates the bake tree and writes the manifest plus `chunk_*.tres` snapshots.
- `world_building_system/building_manager.gd` loads baked building manifests, lazily loads chunk snapshots, and tracks dirty chunks.
- `world_building_system/building_chunk.gd` stores the loaded snapshot state and restores mesh, collision, and object state from a snapshot.
- `world_building_system/prefab_spawner.gd` uses baked chunks in world-map mode and only falls back if a baked chunk is missing.
- `save_manager/save_manager_v2.gd` persists the building-bake toggle and exports dirty baked chunks on world save.
- `world_building_system/building_mesher.gd` still handles runtime meshing for fallback and dirty rebuilds, but it is no longer the roadmap goal.

## Exact Runtime Flow

1. The generator or the town-stall harness saves the world definition.
2. The same flow bakes building snapshots into `baked_buildings/manifest.json` and `chunk_*.tres` files.
3. `SaveManager` loads the baked building manifest when a world path is set.
4. `BuildingManager` keeps the manifest in memory and loads a chunk snapshot only when that chunk is actually needed.
5. `PrefabSpawner` spawns from the baked chunk if the snapshot exists.
6. If the snapshot is missing, the code falls back to the runtime building path for that chunk.
7. Dirty building changes update the runtime chunk view immediately through the normal dirty-chunk flush path.
8. Dirty baked artifacts on disk are updated through save-time dirty export.

## Terms

- Baked building artifact: serialized per-chunk data that contains static building blocks, mesh output, collision output, and static visual batches.
- Dynamic building state: doors, loot, damage, interaction state, or any part that can change after bake.
- Dirty chunk: a chunk that has been edited and must be rebuilt locally.
- Runtime load: the game loading baked artifacts and instantiating them, not regenerating them.
- Fallback generation: the old runtime path, kept only until the baked path is proven.

## Roadmap

| Stage | Status | What happened | Exit criteria |
|---|---|---|---|
| 0. Baseline reset | done | The runtime-reuse experiment was retired and the building bake work started from the world-map bake baseline. | The roadmap no longer depends on a warm runtime cache for success. |
| 1. Artifact contract | done | `BuildingBakeSnapshot` exists, the manifest schema is explicit, and the bake path stores per-chunk snapshot data with versioned resources. | One stable schema exists and can be written and read without guessing. |
| 2. Bake static buildings | done | `WorldMapGeneratorUI` and the town-stall harness bake building snapshots after save/generation, producing baked artifacts for unchanged chunks. | A generated world contains baked building artifacts for unchanged chunks. |
| 3. Runtime loads baked data | done | `BuildingManager` now loads the manifest once and lazily loads per-chunk snapshots only when a chunk is needed. `PrefabSpawner` uses the baked chunk first and falls back only if necessary. | Revisiting an unchanged town does not trigger a full runtime remesh pass for those chunks. |
| 4. Dirty-only rebake | done | Dirty chunks are tracked in memory, flushed locally for the runtime view, and exported back to baked artifacts through save-time dirty export. Unchanged nearby chunks are not forced to rebuild. | Editing one area does not force unchanged nearby areas to rebuild. |
| 5. Proof sweeps | done | Repeat-entry proof runs were executed with baked on and baked off. The baked path measured better town-entry time, while the old fallback path stayed slower. | We can point to the exact before/after gain for buildings. |
| 6. Secondary hotspot review | done | We reviewed the remaining systems and did not expand this roadmap into a new terrain/vegetation/entity bake pass. Those systems are tracked separately if they need their own measured work. | This roadmap stays scoped to buildings and does not guess about unrelated systems. |
| 7. Cleanup and close | done | The baked path is the default. The old runtime-reuse experiment is gone. Test-only toggles remain only for validation and do not define the shipped behavior. | The shipped path is the baked path, not the old runtime generator. |

## Proof Summary

The repeat-entry benchmark showed a measurable improvement from the baked path:

- Baked on: `snapshot_menu_2026-04-20_09-10-42.json`
  - `town_entry_window.avg_total_ms = 14.1547321428573`
  - `town_entry_window.avg_physics_ms = 6.64108885017414`
  - `town_entry_window.avg_draw_calls = 1781.81228222997`
  - `town_entry_window.avg_objects = 2671.45296167247`
  - `building_manager.baked_building_load_profile = { mode = "chunk_load", load_ms = 3.789, loaded_chunks = 1, manifest_chunks = 758 }`
- Baked off: `snapshot_menu_2026-04-20_09-14-04.json`
  - `town_entry_window.avg_total_ms = 17.4578116969428`
  - `town_entry_window.avg_physics_ms = 6.86020292423568`
  - `town_entry_window.avg_draw_calls = 1790.0420912716`
  - `town_entry_window.avg_objects = 2692.37483385024`
  - `building_manager.baked_building_load_profile = { mode = "none", load_ms = 0.0, loaded_chunks = 0, manifest_chunks = 0 }`

That is the building-bake gain this roadmap was after.

## Decision Rules

- If something static can be baked, bake it.
- If something changes rarely and locally, store deltas and rebake only the dirty chunk.
- If something is expensive on first revisit, do not rely on a warm cache hit to hide the cost.
- If something is cheap to rebuild and rarely revisited, keep it runtime-only.
- Do not reopen this roadmap unless the building bake contract itself changes.

## Validation For Each Stage

Every stage should include:

- syntax and parse checks
- a runtime smoke check
- a same-world revisit or repeat-entry proof
- a before/after note that states what got faster and what did not

## Short Version

Bake static building output once.
Load baked building artifacts at runtime.
Only dirty chunks rebuild.
Measure the gains on the same world before adding more caching or native work.
