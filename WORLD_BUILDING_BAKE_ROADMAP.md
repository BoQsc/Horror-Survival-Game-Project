# World Building Bake Roadmap

This file replaces the earlier runtime-reuse experiment.

The goal is not to keep runtime-generated building work warm in memory.
The goal is to move static building output into baked world artifacts so unchanged buildings load directly at runtime without remeshing or rebuilding.

## Why This Roadmap Exists

The runtime-reuse experiment did not produce the building gains we wanted.
The world-map bake is already the right pattern, and the next useful step is to apply that pattern to static building output.

What we want to remove from the runtime path:

- rebuilding unchanged buildings
- remeshing unchanged building chunks
- recalculating unchanged collision and visual batches
- depending on a warm cache hit to hide first-load cost

What we want instead:

- static building output baked once
- runtime loading of baked building artifacts
- dirty-only rebake when a chunk actually changes

## Confirmed Baseline

- `WORLD_MAP_CACHING_ROADMAP.md` is complete.
- The baked world map is already loaded at runtime from disk.
- The old runtime-reuse approach did not give the building gains we expected.
- Buildings remain expensive enough that a bake-first plan is needed.

## Terms

- Baked building artifact: serialized per-chunk or per-settlement data that contains static building blocks, mesh output, collision output, and static visual batches.
- Dynamic building state: doors, loot, damage, interaction state, or any part that can change after bake.
- Dirty chunk: a chunk that has been edited and must be rebaked.
- Runtime load: the game loading baked artifacts and instantiating them, not regenerating them.
- Fallback generation: the old runtime path, kept only until the baked path is proven.

## Explicit Runtime Contract

- Unchanged buildings and building blocks should come from baked artifacts.
- Runtime should not remesh unchanged buildings just because the player came back to the area.
- Only dirty chunks should rebake, and only the touched chunk data should change.
- Static and dynamic building state must stay separate.
- Cache hits are a fallback optimization, not the success criterion.

## What This Roadmap Changes

- Static building output is moved into bake-time artifacts.
- Runtime loads those artifacts directly for unchanged chunks.
- Building mesh, collision, and static visual batches are treated as baked data when they are not changing.
- Revisit performance should improve because less work is done at runtime, not because a cache happened to be warm.

## What This Roadmap Does Not Change

- The baked world-map flow from `WORLD_MAP_CACHING_ROADMAP.md`.
- Save/load correctness.
- Unrelated signal cleanup.
- Unrelated debug helper scripts.
- Broad shader or native rewrites unless profiling proves they are needed.

## Scope

In scope:

- per-chunk building artifact format
- static building block bake output
- mesh, collision, and visual batch bake output for buildings
- runtime instantiation from baked building artifacts
- dirty-only rebake for edited chunks
- telemetry to compare baked load vs fallback generation
- proof runs on the same world path

Out of scope:

- in-memory cache experiments that still remesh unchanged buildings
- unrelated terrain or vegetation refactors unless they are still a hotspot after building bake
- GPU or C++ rewrites before the baked path proves itself

## Roadmap

| Stage | Status | What we will do | Exit criteria |
|---|---|---|---|
| 0. Baseline reset | done | Revert the runtime-reuse experiment and keep the world-map cache baseline as the starting point. The old runtime-reuse path is retired. | The reverted baseline is committed and the roadmap now describes the bake-first plan. |
| 1. Artifact contract | pending | Define the exact per-chunk building artifact schema, including versioning, static block data, mesh data, collision data, and static visual batches. Separate dynamic state from static state. | One stable schema exists and can be written and read without guessing. |
| 2. Bake static buildings | pending | Bake static building output during world generation or save: produce the chunk artifacts for unchanged buildings, blocks, collision, and static visuals. | A generated world contains baked building artifacts for unchanged chunks. |
| 3. Runtime loads baked data | pending | Make `BuildingManager` and the prefab/building path load baked building artifacts directly instead of remeshing unchanged buildings at runtime. | Revisiting an unchanged town does not trigger the normal building generation path for those chunks. |
| 4. Dirty-only rebake | pending | When a building or block changes, rebake only the affected chunk artifact and update the runtime view for that chunk. Keep neighboring chunks unchanged. | Editing one area does not force unchanged nearby areas to rebuild. |
| 5. Proof sweeps | pending | Run the same-world comparison with baked loading on and fallback generation off, then compare against the fallback path. Measure building load time, physics time, draw calls, object counts, and artifact hits. | We can point to the exact before/after gain for buildings. |
| 6. Secondary hot spots | pending | If vegetation or entities are still major hotspots after building bake is in place, apply the same bake-first idea to those systems next. | No new bake stage is added unless measurements justify it. |
| 7. Cleanup | pending | Remove temporary fallback switches once the baked path is the default. Keep one stable building-bake path. | The shipped path is the baked path, not the old runtime generator. |

## Decision Rules

- If something static can be baked, bake it.
- If something changes rarely and locally, store deltas and rebake only the dirty chunk.
- If something is expensive on first revisit, do not rely on a warm cache hit to hide the cost.
- If something is cheap to rebuild and rarely revisited, keep it runtime-only.
- Do not call the plan complete until an unchanged town loads through baked building artifacts with no visible remesh spike.

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
