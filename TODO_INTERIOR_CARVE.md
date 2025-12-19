# TODO: Improve Interior Terrain Carving for Prefabs

## Current Issue
When placing prefabs that are partially inside terrain (e.g., using Road Snap mode), the interior terrain carving feature (`I` key toggle) has **unreliable spilling** - the carving affects terrain outside the prefab boundaries.

## Current Implementation
- Toggle: `I` key in PREFAB mode enables `prefab_interior_carve`
- Logic: Attempts to detect interior columns and carve from floor level upward
- Problem: Carving radius causes spillover into surrounding terrain

## Future Improvement Needed
Implement **accurate Y-axis block-driven carving**:

1. For each block position (X, Z) in the prefab
2. Carve **sharply** (precise 1-voxel cuts) from that block's Y level
3. Carve **upward** until reaching the top block of the prefab at that column
4. Do NOT carve beyond the prefab's block boundaries

### Key Requirements
- Carving must be **sharp/blocky**, not smooth marching cubes transitions
- Each carve should affect exactly 1 voxel, no spillover to neighbors
- Only carve at positions where the prefab actually has blocks defined
- Stop carving at the prefab's maximum height per column

### Potential Approaches
1. Use smaller dig radius (< 0.5) for more precise cuts
2. Consider using material painting instead of density modification
3. Pre-compute a 3D occupancy grid for the prefab and only modify matching voxels
4. Use a post-processing pass to "seal" edges after carving

## Files Involved
- `building_system/prefab_spawner.gd` - `spawn_user_prefab()` function, interior_carve logic
- `player_interaction.gd` - `prefab_interior_carve` toggle, `I` key binding

## Date Added
2024-12-19
