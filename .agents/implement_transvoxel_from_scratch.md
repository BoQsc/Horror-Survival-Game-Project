# Transvoxel From Scratch

## Goal
Build a real Transvoxel far-terrain path without fake shell overlays.

## Rules
- Keep the shared world terrain source.
- Keep exact marching cubes for the near field.
- Use Transvoxel only for 2:1 transitions and far-field blocks.
- Do not create a separate fake terrain world.
- Do not add player-facing toggles until the feature is proven.

## Gates
1. Native extractor compiles.
2. Fixture meshes build for flat, slope, cliff, and corner cases.
3. Seam pair test passes with zero mismatch.
4. Live visual smoke shows the real far mesh.
5. Collision parity is verified.
6. Town benchmark stays within budget.

## Current snapshot
- Branch: `codex/transvoxel-proof-first`
- Shared terrain source exists.
- Preview collision and seam checks are now part of the harness.
- Main risk: feature parity and coherence, not just geometry.
