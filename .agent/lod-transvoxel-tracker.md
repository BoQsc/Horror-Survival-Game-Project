# Transvoxel Tracker

## Branch
- `codex/transvoxel-next`

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
