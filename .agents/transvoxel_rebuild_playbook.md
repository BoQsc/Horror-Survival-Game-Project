# Transvoxel Rebuild Playbook

## Purpose
This is the compact restart guide for rebuilding Transvoxel on this project if the current branch ever has to be abandoned again.

## Known-Good Snapshot
- Commit: `e62ef53` `Snapshot Transvoxel seam and collision baseline`
- Follow-up note commit: `c0ee826` `Record Transvoxel lessons learned`
- Branch: `codex/transvoxel-proof-first`

## Core Architecture
- One shared terrain source:
  - `world_marching_cubes/world_terrain_source.gd`
  - height, biome, road, water, buildings, and edits come from one place
- One terrain data model
- Two mesh backends:
  - exact marching cubes for near terrain
  - Transvoxel for far / transition terrain
- No separate fake terrain world
- No shell / stripe overlay path as the final implementation

## What Fixed the Early "Invisible" Result
- The preview had to be exclusive:
  - hide exact terrain in the preview region instead of drawing both at once
- The Transvoxel mesh had to use the real terrain material path:
  - no blue debug-only material
  - no separate fake world material
- The mesh had to emit a defined vertex color payload:
  - default / undefined vertex state made the shader read wrong
- Triangle winding / culling had to be correct:
  - Godot backface culling will hide the mesh if winding is wrong
- The preview had to be single-sided:
  - do not use a double-sided workaround as the final fix

## What Fixed the Collision Gap
- Visual Transvoxel blocks must also build collision shapes.
- The preview root needs per-block collision bodies, not just meshes.
- The harness now checks for:
  - `StaticBody3D` count
  - `CollisionShape3D` count
- If the collision path is missing, the far terrain is not playable even if it renders.

## Feature-Parity Rules
- Lighting/material parity:
  - far terrain should use the same terrain shader/material logic as near terrain
  - avoid debug tint except in explicit inspection modes
- Water parity:
  - keep water as its own surface path, but feed it from the same shared world data
- Destruction / edits:
  - edits must change the shared terrain source so both backends see the same world
- Building parity:
  - building LOD is a separate system and should not block terrain Transvoxel completion

## Failure Signatures and What They Mean
- Blue stripes:
  - debug tint still active, or a shell-like preview is leaking through
- Dim / dark far terrain:
  - material parity or normals/lighting mismatch
- Merged marching cubes + Transvoxel look:
  - preview is not exclusive, or exact terrain visibility is being handled incorrectly
- Visible far mesh but fall-through:
  - collision path missing or not aligned with the visible preview
- Shapes pop in / seams open:
  - block layout / hide distance / rebuild timing issue
- Far terrain ignores dug-out terrain edits:
  - excavation masks are not wired into the Transvoxel density sampler
- Normals look flat even on cliff fixtures:
  - the fixture is too gentle or the normals path is still being overwritten
- The normals fixture now passes, so if lighting regresses again the cause is likely material/shader parity rather than the geometry normals path.

## Recovery Order
If we ever have to restart again:
1. Check out the known-good snapshot commit.
2. Restore the shared terrain source and the native extractor.
3. Run the preflight gate.
4. Run fixture meshes for flat / slope / cliff / corner.
5. Run seam-pair coverage.
6. Run the visual smoke scene.
7. Verify collision bodies and collision shapes exist in the preview.
8. Verify excavation parity on a carved-out fixture.
9. Verify normals on a real cliff fixture.
10. Only then run the town benchmark.

## Do Not Repeat
- Do not turn Transvoxel into a decorative overlay.
- Do not reintroduce the old shell/stripe prototype as the real answer.
- Do not add player-facing toggles before the feature is proven.
- Do not performance-tune before seam and collision gates pass.
- Do not fork the world into a separate fake `world_transvoxel` implementation.

## Separate System
- Buildings are a separate LOD problem.
- Do not mix building LOD work into terrain Transvoxel restoration.
