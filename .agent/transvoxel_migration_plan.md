# Transvoxel Migration Plan

## Summary
- Keep the terrain density, save/load, building, and gameplay systems intact.
- Use the clean branch to restore the native Transvoxel extractor and add tests before any new in-game visual work.
- Phase 1 is extractor correctness and seam coverage. Phase 2 is a visible in-game smoke path. Phase 3 is performance.

## Gates
- Gate 0: native extractor compiles
- Gate 1: fixture meshes build for flat, slope, cliff, and corner cases
- Gate 2: block layout produces the expected coarse/fine hierarchy and transition masks
- Gate 3: seam pair coverage matches on adjacent blocks
- Gate 4: visual layout smoke shows the block hierarchy in 3D
- Gate 5: smoke run can enable the Transvoxel path in-game
- Gate 6: town benchmark stays within budget with LOD enabled

## Rules
- Do not reintroduce the old shell / stripe prototype as the real implementation.
- Keep the extractor paper-faithful.
- Do not move on to a broader gameplay test if a smaller fixture gate fails.
- Keep visual debug toggles separate from the extractor contract.
- Prove the block layout before wiring live-world terrain placement.
- The new visible proof step should show the block hierarchy, not just isolated seam pairs.
- The visible layout smoke now uses the native Transvoxel meshes again, not fallback boxes.
- Keep one shared world-terrain source for height, biome, road, water, and edits so marching cubes and Transvoxel read the same world state instead of duplicating it.
- Add a seam-gap physics sweep gate before any more live-world tuning:
  - raycast across the transition boundary at multiple seam points
  - fail if any seam sample misses collision
  - include the corner case so a hole cannot hide at the edge
- Once the sweep passes, keep the layout contract symmetrical:
  - mirror transition masks onto the lower-LOD neighbor too
  - keep the live preview and the proof gate using the same seam convention
- Extend the sweep to corner junctions as well as faces so a hole cannot hide where four blocks meet.
- Keep exact-terrain visibility keyed to the same snapped layout anchor as the preview rebuild, not the raw viewer chunk, or the handoff will visibly pop inside one layout.
- Thread the baked excavation masks into the Transvoxel density sampler so the far mesh preserves dug-out voids instead of filling them back in.

## Current branch
- Branch: `codex/transvoxel-proof-first`
- Status: native Transvoxel mesher restored on top of the runtime base, fixture + seam tests passed, and block-layout proof is next.

## Lessons Learned
- Do not restart from a fake shell/stripe layout; that path repeatedly hid the real problem.
- Keep the preview exclusive or it will read like marching cubes plus a dim overlay.
- Use the same world data source for marching cubes and Transvoxel so biomes, roads, water, and edits stay coherent.
- Prove seam coverage and collision before declaring the far mesh usable.
- Visual debug tint belongs only in inspection paths, not in the core feature contract.
- If the far field still feels like separate stripes, treat that as a block-layout / parity issue before touching performance again.
- The first visible Transvoxel result came from fixing the preview path itself: exclusive far mesh, real terrain material, explicit vertex color payload, and correct winding/culling.
- The explicit restart playbook lives in `.agents/transvoxel_rebuild_playbook.md` and captures the known-good snapshot, failure signatures, and recovery order.
- Avoid rebuilding the preview on every viewer chunk step; use the snapped layout anchor as the rebuild key so the same block layout stays stable until the layout actually needs to change.
- The preview harness now verifies collision bodies/shapes exist in the far mesh, so the visible LOD cannot silently regress into a non-playable shell.
- Keep preview swaps atomic: build off-tree, swap only after the replacement is ready, and keep a small overlap buffer so the handoff does not visibly open a seam.
- Excavation parity now has a dedicated proof gate, and the Transvoxel sampler consumes the baked excavation masks so holes do not disappear in the far mesh.
- The exact-terrain hide/show boundary must follow the current viewer chunk as well as the snapped layout anchor, otherwise the transition band reads as a moving pop line.
- A normals proof gate is part of the contract now; use a real cliff fixture so we can catch a flat-normal regression before any gameplay run.
- The normals proof gate now passes, so lighting parity has a concrete fixture-backed check instead of a guess.
