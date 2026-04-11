# Transvoxel Tracker

## Branch
- `codex/transvoxel-proof-first`

## Current Goal
- Build a visually convincing, paper-faithful Transvoxel implementation in a test-first way.
- Keep marching cubes for the exact near field.
- Use Transvoxel only where resolution boundaries need stitching.

## Gates
1. Native extractor compiles
2. Fixture meshes build for core shapes
3. Block layout produces the expected coarse/fine hierarchy and transition masks
4. Seam pair coverage aligns on shared edges
5. Visual in-game smoke gate
6. Town benchmark with LOD enabled

## Current State
- Native `MeshBuilder` Transvoxel methods have been restored from the committed Transvoxel baseline.
- The clean branch now has dedicated fixture and seam-pair tests, and both passed.
- A dedicated visual smoke scene now exists, boots cleanly, and lets the seam pair be inspected in 3D before live-world integration.
- The old shell / stripe prototype is frozen history and should not be revived as the final implementation.
- The live-world coordinator work was intentionally frozen and will be rebuilt only after the proof-first block-layout gate passes.
- A reusable `TransvoxelLayout` helper now exists for the paper-faithful coarse/fine block hierarchy and transition-mask proof.
- The new block-layout test is the next gate before any more in-game integration.
- A dedicated visible block-layout smoke scene now exists and should show the coarse/fine hierarchy in 3D before any live-world wiring is attempted.
- The visible layout smoke now renders the real Transvoxel meshes again, so the block hierarchy can be inspected as actual terrain geometry instead of placeholder boxes.
- A shared `WorldTerrainSource` now centralizes the loaded world-map height, biome, road, and water data so marching cubes and Transvoxel can consume the same terrain source instead of separate ad hoc caches.

## Lessons Learned
- Do not treat Transvoxel as a decorative overlay on top of marching cubes; it must own the far field and hide the exact terrain only by distance.
- If the far terrain looks like blue stripes, the root cause is usually coverage, culling/winding, material parity, or collision parity, not the extractor alone.
- The early "invisible" result was fixed by making the preview exclusive, using the real terrain material path, emitting a defined vertex color payload, and correcting the winding/cull behavior so the far mesh actually stayed visible to the player.
- The preview should rebuild on the snapped Transvoxel layout anchor, not on every raw viewer chunk step; rebuilding every chunk creates avoidable popping and waste even when the layout is unchanged.
- The short preview-town run now verifies the preview root actually contains collision bodies/shapes, so the far mesh is not just visual.
- Keep one shared world-terrain source; duplicated world-map caches quickly drift and cause feature loss.
- Collision must be proved alongside visibility or the far mesh reads as broken gameplay even when the geometry builds.
- Keep debug tint and player-facing toggles out of the core contract; they are inspection aids, not part of the feature.
- Do not performance-tune a seam layout until the seam/collision gates are passing.
- The restart guide lives in `.agents/transvoxel_rebuild_playbook.md` and should be kept in sync with the known-good snapshot commit.
