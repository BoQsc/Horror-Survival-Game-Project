# Seamless Terrain LOD Tracker

## Goal
Make distant marching-cubes terrain cheaper to render while keeping the world visually continuous and predictable.

## Hard Constraints
- No visible popping or mesh swaps.
- No cracks, seams, or T-junction artifacts.
- No gameplay changes for nearby terrain or interactive objects.
- No simplification of doors, windows, crates, pistols, tables, or other town props.
- If the transition is visible, the solution is not acceptable.

## Current State
- The terrain system is chunk-streamed, not LOD-based.
- `world_marching_cubes/chunk_manager.gd` uses render distance and collision distance only.
- `gdextension/src/terrain_grid.cpp` and `gdextension/src/mesh_builder.cpp` do not currently support multiple terrain resolutions.
- The repo already uses 1-voxel chunk overlap for same-resolution seams, but not stitched multiresolution terrain.

## What A True Seamless LOD Would Need
- Near ring: exact marching cubes, unchanged gameplay behavior.
- Mid/far rings: lower-cost terrain representation generated from the same density field.
- Transition handling: stitched boundary geometry or equivalent seam cells.
- Collision: only keep full collision near the player.
- Material/lighting: keep the visual style consistent across rings.

## Likely Technical Direction
- Add a multiresolution terrain path in native code, not a quick GDScript hack.
- Prefer a seam-proof technique such as stitched transition cells rather than a blunt visual swap.
- Keep the existing exact terrain path as the fallback for near-range gameplay.

## Decision Rule
- If the LOD transition can be seen, abort it.
- If the LOD introduces gameplay weirdness, abort it.
- If the system cannot be made predictable, keep the exact terrain and improve performance elsewhere.

## Notes
- This is a research and implementation tracker, not a commitment to ship visible LOD.
- Use it only if profiling shows far-view terrain is still the remaining bottleneck after the current runtime fixes.

## Experiment Plan
1. Keep the current exact terrain path as the baseline.
2. Measure a long enough fixed-seed route to capture:
   - peak frame time
   - average frame time
   - draw calls
   - active chunk count
   - any seam or pop artifacts reported visually
3. Prototype only one far-terrain simplification at a time:
   - coarse far ring generated from the same density field, or
   - heightmap-style far proxy with exact near chunks kept untouched
4. Keep the transition invisible:
   - no hard swaps in the camera view
   - no gameplay changes near the player
5. Accept the idea only if the prototype:
   - improves the fixed-seed benchmark
   - keeps the transition seamless
   - does not break town objects or terrain editing
