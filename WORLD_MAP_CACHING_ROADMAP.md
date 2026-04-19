# World Map Caching and Data Roadmap

This document is the single reference for the world map bake, cache, load, and dirty-update path. It is written to separate confirmed behavior from planned work and from open decisions.

## Terms

- Preview generation: `world_map_generator` creates preview images in memory while the user edits the map.
- Bake: the generator writes PNG layers and `world_meta.json` to disk when the user saves a world definition.
- Runtime load: the game scene loads the baked files from disk through `WorldMapData`.
- Dirty update: only the chunks or runtime systems touched by a change are rebuilt.
- Cache: the in-memory world data stored by `WorldMapData` for a world path.

## Confirmed in This Branch

| File | Confirmed role |
|---|---|
| `world_map_generator/world_map_generator_ui.gd` | Generator UI. Handles edit preview, save, and play handoff. Invalidates stale world cache after save. |
| `world_map_generator/world_map_generator.gd` | Bake engine. Generates and writes the baked PNG layers and `world_meta.json`. |
| `world_map_data/world_map_data.gd` | Runtime loader/cache. Loads baked files, keeps an LRU cache, and supports enable/disable plus invalidation. |
| `world_marching_cubes/chunk_manager.gd` | Runtime terrain owner. Reads the baked world path, loads the data through `WorldMapData`, and rebuilds dirty terrain state. |
| `modules/world_player_v2/features/ui_hud/hud_minimap.gd` | Minimap consumer. Loads the same baked world data for map display. |
| `save_manager/save_manager_v2.gd` | Persists the pending world path and the cache toggle across scene changes and save/load. |
| `world_building_system/prefab_spawner.gd` | Runtime building/prefab spawn behavior. Uses baked world data when world map mode is active. |
| `world_vegetation/vegetation_manager.gd` | Runtime vegetation refresh. Reacts to chunk changes instead of rebaking the world. |

## Explicit Bake Timing

1. The user edits the map in the generator UI.
2. If the user presses Generate, the generator updates preview data in memory.
3. If the user presses Save, the generator writes the baked PNG layers and `world_meta.json` to the world folder.
4. The generator invalidates the cached entry for that world path after save.
5. If the user presses Play, the generator saves first, stores `pending_world_definition_path` in `SaveManager`, and changes to the game scene.
6. On runtime startup, `chunk_manager` reads the pending path, applies the cache toggle, and loads the baked files through `WorldMapData`.
7. While the world is active, edits are handled as dirty runtime updates.
8. If the user saves a new bake or switches worlds, the old cache entry is invalidated and the new baked files are loaded.

## Explicit Runtime Contract

- The runtime does not rerun the full world generator on every frame.
- The runtime does not rebake the entire world map just because a player changed something.
- Player terrain edits only mark affected chunks dirty and rebuild those chunks and their dependent runtime data.
- Runtime systems that depend on changed terrain or buildings update only the affected region or queue.
- The baked world files stay on disk; the runtime loads them into memory and reuses them while the world is active.
- Cache behavior is optional, but the default is enabled.
- Current cache behavior returns duplicated data by default so callers do not accidentally mutate cached originals.
- `WorldMapData` currently keeps a small LRU cache of four world entries.
- If `water.png` is missing, the loader falls back to `structures.png`.
- If `world_meta.json` is malformed, the loader ignores the metadata instead of crashing.

## What "Changed Stuff" Means at Runtime

When we say "only changed stuff gets updated", we mean:

- Terrain chunks touched by a dig, fill, or terrain edit.
- Chunk meshes, physics bodies, and collision data for those chunks.
- Vegetation that lives on or near modified chunks.
- Prefab and building spawn state that belongs to the changed world region.
- Minimap overlays that reflect the changed world data.
- Any save data that records runtime changes.

It does not mean:

- Recreating the full baked world map.
- Rerunning the entire generator.
- Reloading the whole game scene just because one chunk changed.

## Roadmap

| Stage | Status | What we will do | Exit criteria |
|---|---|---|---|
| 0. Current baseline | done | Keep the current branch wiring: generator UI, bake engine, `WorldMapData` loader/cache, chunk manager runtime loading, minimap consumer, and persisted cache toggle. | The current code path stays intact and documented. |
| 1. Data contract | next | Lock the baked file names, layer names, metadata keys, and compatibility rules into one explicit contract. Keep legacy alias handling documented, including the current water fallback. | Old and new baked worlds load through the same documented schema. |
| 2. Dirty-update boundaries | next | Make every runtime system that reacts to world edits explicitly update only its affected chunks, objects, or overlays. Confirm the update path for terrain, vegetation, buildings, prefab spawns, and minimap data. | A player edit only rebuilds the affected runtime regions. |
| 3. Cache policy | next | Keep the cache toggle optional and default-on. Define when cache entries are invalidated, when they are evicted, and when callers get copies versus shared handles. | Cache behavior is documented and consistent everywhere. |
| 4. Measurement | next | Add timing around bake preview generation, disk save, JSON parse, image decode, runtime world entry, chunk rebuild, vegetation refresh, prefab spawn processing, and minimap build. | We know which step costs the most. |
| 5. Hot-path optimization | later | After measurement, optimize only the proven bottleneck. If the bottleneck is GDScript load/cache work, move that hot path to GDExtension/C++. If the bottleneck is generation, move that work to compute or another GPU path. | The measured bottleneck is faster without changing the public behavior. |
| 6. Scale-up and streaming | later | Only if world size or content makes it necessary, add region loading, tile loading, partial invalidation, or larger-world memory control. | Larger worlds load without full-world churn. |
| 7. Cleanup | later | Remove redundant helpers, stale names, compatibility shims, and transitional comments after the replacement path is proven. | One clear path remains. |

## Not Decided Yet

- Whether runtime consumers should keep duplicated read-only data or switch some paths to shared read-only handles.
- Whether C++/GDExtension or GPU compute is the first real optimization after profiling.
- Whether region loading or streaming is needed at all.

## Rules

- Do not rebake the whole world at runtime.
- Do not change the baked file format without versioning it.
- Do not move to C++ or GPU work before profiling shows that the current GDScript path is the bottleneck.
- Do not fold unrelated `PlayerSignals` or `ContainerSignals` cleanup into this roadmap unless it blocks validation.
- Keep the cache toggle optional, but default it to enabled.

## Validation For Each Stage

Every stage should include:

- syntax and parse checks
- a runtime smoke check
- a targeted load test for the touched files

## Short Version

Bake in the generator. Save the baked files to disk. Load the baked files at runtime. Rebuild only the dirty runtime pieces that changed. Measure before optimizing. Move to C++ or GPU only if profiling says it is worth it.
