# TODO: Improve Interior Terrain Carving for Prefabs

## Current Issue
When placing prefabs that are partially inside terrain (e.g., using Road Snap mode), the interior terrain carving feature (`I` key toggle) has **unreliable spilling** - the carving affects terrain outside the prefab boundaries.

## Current Implementation
- Toggle: `I` key in PREFAB mode enables `prefab_interior_carve`
- Logic: Attempts to detect interior columns and carve from floor level upward
- Problem: Carving radius causes spillover into surrounding terrain

## Current Recommended Workflow
For now, work around the interior carve limitations:

1. **Urban areas (cities/towns)**: Use **flattened terrain areas** for building placement
   - Create flat zones in terrain generation for urban development
   - Buildings place cleanly on flat ground without interior carve issues
   
2. **Isolated buildings in open terrain**: May require **manual labor**
   - Interior carve may cause visible artifacts
   - Entrance stairs might not properly reach the terrain
   - Use manual terrain editing (dig mode) to clean up if needed

3. **Best combination for placement**: Surface + Road Snap (`T` key)
   - Places buildings at consistent road level
   - Doors accessible from roads

## Future Improvement Needed
Two possible approaches:

### Option A: Smaller, More Accurate Smooth Carving (Easier)
Keep marching cubes, but improve accuracy:
1. Use **smaller dig radius** (e.g., 0.3-0.4 instead of 0.6)
2. Only carve at **exact block positions** within prefab interior
3. Reduce spillover by limiting carve strength
4. Accept slight smoothing at edges (MC limitation)

### Option B: Sharp Block-Driven Carving (Requires Dual Contouring)
For truly sharp 90° cuts:
1. Would require reimplementing terrain from Marching Cubes to **Dual Contouring**
2. Dual contouring preserves sharp features but is significantly more complex
3. Not worth the effort just for this feature

### Recommended: Option A
Smaller, more accurate carving with marching cubes is the practical solution.

### Implementation Notes
- Carve from each block's Y level upward to top of prefab at that column
- Only carve at positions inside the prefab bounding box (1+ block from edges)
- Test with progressively smaller radii until spillover is minimized

## Files Involved
- `building_system/prefab_spawner.gd` - `spawn_user_prefab()` function, interior_carve logic
- `player_interaction.gd` - `prefab_interior_carve` toggle, `I` key binding

## Date Added
2024-12-19
