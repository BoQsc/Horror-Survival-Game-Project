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
- The next gate is a seam-gap physics sweep that raycasts across the transition boundary and fails on open holes or missing collision coverage.
- The seam-gap sweep now passes on the live layout, and the layout helper now mirrors transition masks onto the lower-LOD neighbor so both sides of the seam stay in the same proof contract.
- The seam-gap sweep now also checks corner junctions, because face-only checks can miss a hole where four blocks meet.
- Exact terrain visibility now follows the same snapped layout anchor as the preview rebuild, so the handoff does not chase raw viewer chunks and pop inside the same layout.
- The preview swap must be atomic: build the replacement layout off-tree, keep the old preview alive until the new one is ready, then swap it in and free the old root.
- A small overlap buffer on the exact-terrain hide distance helps cover the handoff edge without reintroducing the old shell overlay behavior.
- Excavation masks must be threaded into the Transvoxel density sampler too, or the far mesh will ignore the same dug-out holes that the live terrain already knows about.
- The exact-to-Transvoxel handoff also needs a small safety overlap buffer; otherwise the player sees the seam pop open while the replacement layout finishes swapping in.
- Exact-terrain visibility must follow the current viewer chunk, not just the snapped layout anchor, or the cut line lags behind the player and reads like popping/gaps.
- The normals proof gate uses a real cliff fixture now; the earlier "cliff" sample was too gentle and produced a false flat-normal failure.
- The normals proof gate now passes on the real cliff fixture, so the far mesh lighting path is no longer just assumed to be correct.
