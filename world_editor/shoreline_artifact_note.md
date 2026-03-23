# Shoreline Artifact Note

Last verified: 2026-03-23

## Symptom

We saw a broad shoreline strip / shelf appear near towns by water in the world editor. It looked like an unintended terrain artifact, not a church mesh issue.

## What caused it

The lake generation pass in `world_editor/world_map_generator.gd` was treating access paths the same as full roads.

Relevant details:

- `_rasterize_paths()` writes access paths into `road_bytes` with a lower mask value than main roads.
- `_generate_lakes()` was checking `road_bytes > 128` before allowing water to appear.
- That meant access paths could block lake generation and push the shoreline back, leaving the visible dry corridor.

## Fix applied

We narrowed the lake exclusion rule so only true road cores block lake generation.

Current guard:

- `LAKE_ROAD_BLOCK_THRESHOLD = 240`
- `_generate_lakes()` now skips only cells with `road_bytes >= LAKE_ROAD_BLOCK_THRESHOLD`

This keeps the fix generic and avoids hardcoding anything for the church prefab.

## Relevant code locations

- `world_editor/world_map_generator.gd` `_rasterize_paths()`
- `world_editor/world_map_generator.gd` `_generate_lakes()`
- `world_editor/world_map_generator.gd` `LAKE_ROAD_BLOCK_THRESHOLD`

## If this comes back

If shoreline shelves reappear, the next step is to split the road mask into explicit categories instead of using one shared `road_bytes` layer for both:

- main roads
- access paths
- shoreline protection

That would make the lake pass less dependent on threshold values.
