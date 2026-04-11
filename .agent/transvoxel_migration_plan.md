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

## Current branch
- Branch: `codex/transvoxel-proof-first`
- Status: native Transvoxel mesher restored on top of the runtime base, fixture + seam tests passed, and block-layout proof is next.
