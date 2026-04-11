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
4. Seam-gap physics sweep proves there are no open holes.
5. Live visual smoke shows the real far mesh.
6. Collision parity is verified.
7. Town benchmark stays within budget.

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
- The seam-gap physics sweep is the missing proof step for open holes/fall-through, and it must pass before the branch is treated as safe.
- The seam-gap physics sweep now passes on the live layout, and the layout helper mirrors transition masks onto the lower-LOD neighbor so the seam convention stays symmetric.
- The seam-gap proof must include corners, not just faces, because corner holes can survive a face-only sweep.
- The exact-terrain hide/show boundary must follow the snapped layout anchor, not the raw viewer chunk, or the handoff will pop even when the seam proof passes.
- The cut line should also be checked against the current viewer chunk, because a pure layout-anchor cut can still lag behind the player and look like popping/gaps.
- Preserve the preview handoff: build the replacement layout off-tree, swap it in only after it is complete, and keep a small overlap buffer so the exact-to-Transvoxel boundary does not visibly tear open.
- Excavation masks are part of parity too; if the far mesh ignores dug-out chunks, it will still read as feature-loss even when the seam is watertight.
- The normals gate needs a genuinely steep cliff fixture; a gentle gradient can hide a broken lighting path and produce a false failure or false pass.
- The normals gate now passes on that steep cliff fixture, so lighting parity has a real fixture-backed baseline.
