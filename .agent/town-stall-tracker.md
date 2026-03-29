# Town Stall Tracker

Last updated: 2026-03-28

This is the working record for the town-entry stall and the path to a stable 60 FPS baseline.

## Goal

- Keep gameplay, visuals, and interaction intact.
- Eliminate the town-entry stall without breaking the sandbox.
- Prefer real work reduction over mitigation.

## Locked Baselines

- Roads and building paths are considered a separate, mostly-stable track.
- Vegetation batching experiments are out of scope for the stall work.
- Do not minimize/focus/steal attention from other windows during tests.
- Do not change visuals or interaction for gameplay objects like windows, doors, crates, pistols, stones, or plants unless explicitly approved.

## What We Have Proven

- The town stall is real.
- Building work is a major contributor.
- Buildings-off reduces the entrance spike dramatically.
- The worst recent peaks line up with large `new_wooden_house_2floor_secret_facility` spawns, not with chunk collisions alone.
- Disabling building chunk collisions or building chunk mesh render did not materially remove the stall.
- Skipping redundant runtime carving for baked world-map prefabs was a major win:
  - the large church spawn dropped from `73.605 ms` object time with `11.774 ms` carve time to `5.435 ms` object time with `0.0 ms` carve time
  - the town-entry peak dropped from `142.644 ms` to `60.554 ms`
  - frames over `50 ms` fell to `1`
- Roads are not the current bottleneck.
- Vegetation is not the current bottleneck.
- The test harness and fixed-seed route are valid for comparison.

## Current Leading Hypothesis

- The remaining hot path is now mostly render-side town complexity plus the last bits of building/object setup:
  - prefab spawn / object setup
  - render flush / draw-call pressure from the town scene
  - any remaining overlap between terrain finalization and visual batch rebuilds
- Terrain finalization overlapping with building/visual-batch work is still a likely secondary cost, but it is no longer the main source of the huge stall.

## Current Helpful Levers

- Native/C++ work for hot CPU loops.
- Reduce repeated building flush/rebuild work.
- Reduce prefab spawn cost for repeated town props.
- Keep terrain finalization from competing with building, prefab, and visual-batch backlog.
- Only keep changes that show a measurable improvement in the fixed-seed town test.

## What Has Been Ruled Out

- Roads/path shaping as the town-stall cause.
- Vegetation batching as the main fix.
- Window-state tricks in the test runner.
- Prewarm as the primary solution.
- Broad visual downgrades or placeholder proxies for gameplay-critical objects.

## Current Working Areas

- `world_building_system/building_manager.gd`
- `world_building_system/prefab_spawner.gd`
- `world_building_system/building_chunk.gd`
- `world_marching_cubes/chunk_manager.gd`

## Testing Rule

- Run the town-stall test only after a concrete code change that is likely to matter.
- Compare against the same seed and the same entry route.
- Use the town-entry burst, not long-window averages, as the main signal.

## Recent Direction

- A small world-map prefab spawn budget cap helped.
- Terrain finalization deferral while building work is pending helped.
- Terrain finalization also now waits for pending prefab spawn backlog and pending visual-batch rebuilds.
- Skipping redundant world-map prefab carving was the biggest recent win.
- The work is now about shaving the remaining render tail and any remaining building/terrain overlap, not revisiting roads or vegetation.
