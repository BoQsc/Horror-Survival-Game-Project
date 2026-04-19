# World Map Caching and Data Roadmap

This document is the single reference for the world map caching and data work.

## North Star

Runtime should load baked world data once, keep it in memory, and reuse it for terrain, minimap, building overlays, and save/load handoff. World generation should happen in the editor/bake path, not repeatedly at runtime.

## Current State

- `world_map_generator` is the bake/save side.
- `WorldMapData` is the shared runtime loader/cache.
- `chunk_manager`, `hud_minimap`, and the generator UI already use the shared loader.
- The cache toggle is optional, enabled by default, and persisted through `SaveManager`.
- Saving invalidates the cached world entry so edited data does not stay stale.

## What We Still Need To Work On

| Stage | Goal | Work Items | Done When |
|---|---|---|---|
| 1. Canonical data contract | Make the baked world format explicit and stable | Lock layer names, metadata keys, and legacy aliases; add versioning to `world_meta.json`; document read-only vs mutable data | Old and new worlds load through the same API without guesswork |
| 2. Zero-churn runtime loads | Avoid unnecessary copies after the first load | Let runtime consumers opt into shared read-only handles instead of duplicated images; keep invalidation on save and world switch | Runtime enters a world without rereading or re-decoding map files |
| 3. Cache policy | Make caching behavior predictable | Keep default on; expose the toggle in UI/settings; define LRU/eviction and cache clear rules; add cache telemetry | Cache can be turned on/off without stale data or hidden state |
| 4. Measurement | Know where the real cost is | Add timing around decode, JSON parse, texture creation, minimap build, and world entry | We can point to actual bottlenecks before moving to native or shader work |
| 5. Native acceleration | Move the expensive hot path out of GDScript if needed | Port only measured hotspots to GDExtension/C++; keep the public API stable | GDScript stops being the bottleneck for the measured hot path |
| 6. GPU generation | Use shaders where they are the best fit | Move terrain/biome/road generation to compute if profiling says it matters; keep save/load orchestration on CPU | World bake time drops materially and stays deterministic |
| 7. Scale-up | Support larger worlds or more complex streaming | Add region or tile loading, partial invalidation, and bigger-world memory control if needed | We can grow without forcing full-map reloads |
| 8. Cleanup | Remove transitional code only after the new path is proven | Delete redundant helpers, stale aliases, and old comments/docs once the new path is stable | The codebase has one obvious path instead of several overlapping ones |

## Working Rules

- Keep the cache toggle optional, but default it to enabled.
- Prefer shared in-memory world data for runtime consumers when they are read-only.
- Preserve backward compatibility for old world saves and baked map files until the migration window is intentionally closed.
- Do not move to C++ or shader work until profiling shows the GDScript path is actually the bottleneck.
- Keep unrelated `PlayerSignals` / `ContainerSignals` cleanup out of this feature track unless it blocks validation.

## Validation Rule

Each stage should land as a small change with validation attached:

- syntax / parse scan
- runtime smoke check
- targeted world-load check for the touched files

## Status Markers

- `done` means the code is already in the branch.
- `next` means we should work on it soon.
- `later` means it matters, but only after the current path is stable.

## Short Version

The immediate path is:

1. Stabilize the baked data contract.
2. Remove unnecessary copies in runtime loads.
3. Measure the actual cost.
4. Decide whether C++ or GPU work is worth it.
5. Stream or scale only if the world size justifies it.
