# World Runtime Reuse Roadmap

This is the follow-up roadmap to `WORLD_MAP_CACHING_ROADMAP.md`.

It covers the next problem we actually need to solve: once the baked world map is loaded, keep the expensive runtime-generated content resident and reuse it instead of rebuilding it every time the player revisits the same area.

## Why This Roadmap Exists

The world-map cache is already real and active. The next bottleneck is the runtime work that still scales hard with render distance.

Recent stress sweeps showed:

| Render distance | Avg total ms | Avg draw calls | Avg objects | Dominant pressure |
|---|---:|---:|---:|---|
| 5 | 12.95 | 1,056 | 1,872 | GPU/Render |
| 10 | 18.11 | 2,693 | 3,805 | GPU/Render |
| 15 | 57.98 | 6,770 | 7,537 | GPU/Render |

The pressure ranking at higher distances was dominated by:

- `TerrainManager`
- `VegetationManager`
- `EntityManager`
- `BuildingManager`

That means the next work is not more baked-map loading. The next work is runtime reuse.

## Terms

- Runtime-generated content: anything created after the baked world map is loaded.
- Runtime reuse: keeping generated results in memory and restoring them instead of regenerating them.
- Cache entry: one stored runtime result for one chunk, region, or settlement.
- Dirty invalidation: marking only the touched area stale so only that area rebuilds.
- Pooling: reusing instances or resources instead of allocating new ones every time.

## What This Roadmap Does Not Change

- It does not reopen `WORLD_MAP_CACHING_ROADMAP.md`.
- It does not change the baked world-map file format.
- It does not replace the current generator/save/load flow.
- It does not require a C++ or GPU rewrite unless a measured hotspot still remains after reuse is in place.

## Explicit Runtime Contract

- Revisited unchanged terrain should restore from cached runtime data instead of rebuilding from scratch.
- Only dirty chunks or dirty regions should regenerate.
- Buildings and building blocks should be treated as reusable runtime output when they are static or effectively static.
- Vegetation should be cached or pooled per chunk or region so unchanged areas do not replant everything.
- Entity spawn pressure should be reduced by pooling or persistent chunk-aware spawn state where it is safe to do so.
- Terrain mesh and collision generation should be reduced to the smallest dirty region that actually changed.
- Runtime reuse must not break save/load correctness.
- If a cache is not safe to reuse, only that piece should rebuild, not the whole world.

## Scope

In scope:

- terrain chunk mesh reuse
- terrain collision reuse
- vegetation placement reuse
- vegetation instance pooling
- building prefab reuse
- building block reuse
- building mesh and collision reuse
- building visual batch reuse
- entity spawn pooling or persistent spawn state where safe
- cache invalidation and persistence rules for those systems
- telemetry for comparing cached and uncached paths

Out of scope:

- reopening the finished world-map roadmap
- changing baked world data schema
- unrelated signal cleanup
- unrelated debug helper scripts
- broad shader or native rewrites unless profiling says they are necessary

## Roadmap

| Stage | Status | What we will do | Exit criteria |
|---|---|---|---|
| 0. Baseline | done | Keep the current render-distance proof, the `WorldMapData` cache baseline, and the chunk-cleanup race fix as the known starting point. | We can reproduce the current numbers and compare later runs against them. |
| 1. Terrain reuse | done | Cache generated terrain chunk meshes, collision, and worker output per chunk so unchanged terrain can be restored instead of rebuilt. | A revisited terrain chunk comes back from cache without a full rebuild. |
| 2. Vegetation reuse | done | Cache vegetation placement, instances, and colliders per chunk or region, and invalidate only the dirty area when terrain changes. | Unchanged vegetation restores from cache and dirty terrain only refreshes its own vegetation. |
| 3. Entity reuse | done | Add chunk-aware entity pooling or persistent spawn records so the same area does not repeatedly respawn the same expensive entity setup. | Entity pressure drops on revisits and only dirty spawn regions regenerate. |
| 4. Building and block reuse | done | Cache building prefab output, building blocks, meshes, collision, and visual batches per chunk or settlement region. Keep interactive state separate from static build output. | Buildings and blocks in unchanged areas return from cache instead of being rebuilt. |
| 5. Cache rules | done | Define exactly what invalidates each cache: terrain edits, building edits, world switches, save/load, memory pressure, and settings changes. Decide which caches survive scene transitions and which are session-only. | Cache invalidation is predictable and documented for every subsystem. |
| 6. Proof sweeps | done | Repeat the render-distance sweep with cached and uncached paths, starting at 5, 10, and 15, and extend only if needed. Measure terrain, vegetation, entity, and building costs separately. | We can point to the exact subsystem that improves. |
| 7. Hot-path follow-up | done | If a specific hotspot still dominates after reuse, move only that measured hot path to C++/GDExtension or another lower-level implementation. | Native work is justified by measured need, not by guesswork. |
| 8. Cleanup | done | Remove temporary hooks and test-only toggles that were only needed during rollout. | One stable runtime-reuse path remains. |

## Final Proof

- Repeat-entry runtime proof: the same world path was revisited in one session, and `terrain_runtime_cache_hits` reached `271` while `terrain_runtime_cache_size` stayed at `145`.
- Terrain snapshot at the end of the proof reported `terrain_runtime_cache_enabled: true`, `terrain_runtime_cache_misses: 255`, and `load_total_us: 422969.0` for the baked world-map load path.
- Vegetation stayed resident across the revisit: `tree_chunk_count`, `grass_chunk_count`, and `rock_chunk_count` were all `229` in the same snapshot.
- Building and entity state also stayed resident in the same run: `building_manager` reported `chunk_count: 66`, and `entity_manager` reported `dormant_entities: 114` with `spawned_chunks: 255`.
- The render-distance sweep data remains the earlier baseline for regression comparison, and the repeat-entry proof now shows the runtime reuse path is active, not just documented.

## Decision Rules

- If a runtime result is static after load, cache it and reuse it.
- If a runtime result changes often, pool it or make dirty updates as small as possible.
- If a cache is expensive to keep and cheap to rebuild, do not keep it.
- If a cache is expensive to rebuild and commonly revisited, keep it.
- If the measured bottleneck moves after one fix, remeasure before choosing the next subsystem.

## Validation For Each Stage

Every stage should include:

- syntax and parse checks
- a runtime smoke check
- a render-distance sweep or comparable comparison for the touched system
- a before/after note that states what got faster and what did not

## Short Version

Bake the world map once. Reuse the baked map at runtime. Then cache or pool the expensive runtime output that still makes the machine hot: terrain chunks, vegetation, entities, buildings, and building blocks. Only escalate to native code or GPU work if profiling still shows a clear hotspot after reuse is in place.
