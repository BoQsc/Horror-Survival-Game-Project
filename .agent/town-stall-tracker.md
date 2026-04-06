# Town Stall Tracker

Last updated: 2026-03-30

This is the working record for the town-entry stall and the path to a stable 60 FPS baseline.

## Goal

- Reach a stable 60 FPS-feeling experience.
- Keep gameplay, visuals, and interaction intact.
- Eliminate the town-entry stall without breaking the sandbox.
- Make building loading effectively unnoticeable to the player.
- Prefer simple fixes that reduce real work over clever but cumbersome algorithms.
- Use shader or GDExtension only when they clearly help and do not change gameplay.

## Locked Baselines

- Roads and building paths are considered a separate, mostly-stable track.
- Vegetation batching experiments are out of scope for the stall work.
- Do not minimize/focus/steal attention from other windows during tests.
- Do not change visuals or interaction for gameplay objects like windows, doors, crates, pistols, stones, or plants unless explicitly approved.
- Do not assume a volumetric/gameplay prop is safe to batch visually just because the scene file looks simple; verify gameplay impact first.

## What We Have Proven

- The town stall is real.
- Building work is a major contributor.
- Buildings-off reduces the entrance spike dramatically.
- Splitting world-map prefab object spawning across frames was a real win:
  - the town-entry peak is now down to about `35.725 ms` on the fixed-seed route
  - frames over `40 ms` and `50 ms` are both `0` on the latest validated run
  - the remaining peak sample is now `Engine: Physics` instead of a giant spawn burst
- The worst recent peaks line up with large `new_wooden_house_2floor_secret_facility` spawns, not with chunk collisions alone.
- Disabling building chunk collisions or building chunk mesh render did not materially remove the stall.
- Skipping redundant runtime carving for baked world-map prefabs was a major win:
  - the large church spawn dropped from `73.605 ms` object time with `11.774 ms` carve time to `5.435 ms` object time with `0.0 ms` carve time
  - the town-entry peak dropped from `142.644 ms` to `60.554 ms`
  - frames over `50 ms` fell to `1`
- Switching world-map buildings back to merged box colliders kept the town peak lower than the shape path without changing gameplay behavior.
- Roads are not the current bottleneck.
- Vegetation is not the current bottleneck.
- The test harness and fixed-seed route are valid for comparison.
- The world-map prefab object priority sort was reversed once by a `pop_back()` queue and caused delayed visible props; that was fixed so doors/windows come first again.
- A per-prefab object-definition cache and a budgeted global visual-batch flush were tried and rolled back because they regressed the town run.
- The peak-frame capture now stores the exact worst town sample in the snapshot so we can inspect the real spike instead of guessing from averages alone.
- The entity proximity loop had a freed-object TypedArray bug and was fixed by making the invalid-entity scratch array untyped.

## Current Leading Hypothesis

- The remaining hot path is now mostly building/object setup plus the remaining render tail:
  - prefab spawn / object setup
  - render flush / draw-call pressure from the town scene
  - any remaining overlap between terrain finalization and visual batch rebuilds
- Terrain finalization overlapping with building/visual-batch work is still a likely secondary cost, but it is no longer the main source of the huge stall.
- The best remaining wins should come from simplifying the building pipeline, not inventing complicated new systems.
- The rotated prefab-object cache did not clearly pay for itself, so the simpler raw spawn path remains the baseline.
- Occupied-cell calculation is now centralized in `ObjectRegistry`, so the spawner and validation paths share one cached implementation instead of maintaining a second per-prefab rotation-cell cache.
- The shared occupied-cell cache warmup was tried and removed because it did not clearly improve the town-entry peak enough to keep.
- The temporary per-prefab object metadata cache was tried and removed because it did not clearly improve the town-entry peak enough to keep.
- World-map dirty-chunk flushing now caps itself to 2 chunks per flush so one burst cannot rebuild too many building chunks in the same frame.
- The town-entry spike window now uses `town_buildings_chunk_count` to ignore the empty baked-queue background while still keeping real building batch-flush and object-collision spikes in view.
- If the current GDScript path is still too costly, the next step is a straightforward native helper for the hot loop, not a broader gameplay rewrite.
- The current validated town baseline is now about `35.725 ms` peak with `0` frames over `40 ms` and `0` frames over `50 ms` on the fixed-seed route after the spawn resume split landed.

## Current Helpful Levers

- Native/C++ work for hot CPU loops.
- Reduce repeated building flush/rebuild work.
- Reduce prefab spawn cost for repeated town props.
- Keep terrain finalization from competing with building, prefab, and visual-batch backlog.
- Only keep changes that show a measurable improvement in the fixed-seed town test.
- Prefer the simplest algorithm that meets the target, not the cleverest one.
- Preserve the current stable visual/gameplay path unless a new change is measurably better.
- Keep the world-map spawn queue readable and simple: nearest buildings first, visible props first, no delayed empty-town behavior.

## What Has Been Ruled Out

- Roads/path shaping as the town-stall cause.
- Vegetation batching as the main fix.
- Window-state tricks in the test runner.
- Prewarm as the primary solution.
- Broad visual downgrades or placeholder proxies for gameplay-critical objects.
- Treating any volumetric gameplay prop as a safe static visual batch candidate without explicit verification.

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
- The work is now about reducing object-placement churn and any remaining render tail, not revisiting roads or vegetation.
- Keep the town loading route simple: visible buildings first, no fake proxies, no extra gameplay-visible delays.
- The world-map prefab object order is now pre-sorted at load time so the spawn loop no longer re-sorts the same list on every building.
- The world-map prefab object metadata is now precomputed at load time so the spawn loop does not keep asking ObjectRegistry for the same size/collision data.
- The world-map prefab object occupied cells used to be precomputed per prefab and per rotation, but that duplicated the same shape data in two places. The occupied-cell calculation is now centralized in `ObjectRegistry`, and the spawner asks for the cached cells directly when it needs them.
- The latest fixed-seed town run after the object spawn resume split landed at `35.725 ms` peak with `0` frames over `40 ms` and `0` frames over `50 ms`, and the remaining peak sample is now `Engine: Physics`.
- The latest object-cache experiment was rolled back because it did not clearly improve the town entry enough to justify the extra complexity.
- The occupied-cell cache is now centralized instead of duplicated in the spawner, which keeps the code simpler while preserving the same placement results.
- The compact integer cache-key variant for occupied cells was tried and rolled back because it did not improve the town-entry peak enough to keep.
- A small `BoxShape3D` reuse cache for merged world-map building collisions is now in place; it keeps collision behavior the same while reducing shape allocation churn.
- A viewer-distance sort on the apply queue was tried and then removed because it did not improve the result enough to keep.
- The world-map object-mix bookkeeping skip was reverted because it did not measurably move the town-entry peak.
- Lowering the building apply queue from 4 to 3 was tried and rolled back because it did not lower the peak and increased the over-budget tail.
- The town-entry capture is now anchored to the approach buffer around the town radius instead of the whole flight, which makes the measurement much closer to the actual entrance.
- The latest validated approach-window run is `20.043 ms` peak with `0` frames over `40 ms` and `0` frames over `50 ms`.
- The peak sample is `GPU/Render (719 draws)`, while the building and terrain queues are quiet at that moment, so the entrance stall is effectively gone on the fixed-seed route.
- The remaining later spike during extended hold is still worth watching, but it is no longer the entrance problem we were chasing.
- The stable world-map spawn ordering fix remains in place, but the temporary sorted-object cache and aggressive flush-budget tweak were rolled back because they did not improve the town-entry result enough to keep.
- The latest validated full-town approach-window run is back to a strong baseline: `35.725 ms` peak with `0` frames over `40 ms` and `0` frames over `50 ms`.
- The remaining peak frame is now `Engine: Physics`, but it stays below the stall threshold on the fixed seed, so the entrance is currently in a safe state again.
- The prefab-object sorted cache experiment did not earn its keep and was removed again after a follow-up run showed a worse peak (`107.653 ms`) on the same fixed route.
- The useful takeaway from that dead-end is that queue ordering still matters, but extra caching around it did not provide a stable win.
- After the cache rollback, the fixed-seed full-town approach-window run returned to a safer baseline: `28.57 ms` peak with `0` frames over `40 ms` and `0` frames over `50 ms`.
- The current remaining peak stays in `GPU/Render`, but it is below the stall threshold and no longer points at a regression in the spawn queue itself.
