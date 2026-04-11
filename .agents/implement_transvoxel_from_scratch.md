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

## Lessons Learned
- The important failure mode is not “does it render,” but “does it stay coherent with the rest of the world.”
- A Transvoxel far mesh that is visible but dim, stripe-like, or separable from the near terrain is still not done.
- The early invisibility problem was solved by making the preview exclusive, using the real terrain material, emitting a defined vertex color payload, and fixing winding/cull behavior so the player could actually see the far mesh.
- Rebuild the preview on the snapped layout anchor instead of every raw viewer chunk; otherwise the far field pops and wastes work even when the layout is unchanged.
- The preview harness now checks for collision bodies and shapes, which prevents the far mesh from silently regressing into a visual-only shell.
- Never ship a branch where the preview hides the collision path or the collision path hides the preview path.
- Keep the far mesh on the same lighting/material rules as the terrain, otherwise it reads as fake even when the geometry is correct.
- Building LOD is a separate system and should stay out of the terrain parity contract for now.
- The restart playbook lives in `.agents/transvoxel_rebuild_playbook.md` and should be treated as the real recovery path if the branch has to be rebuilt.
