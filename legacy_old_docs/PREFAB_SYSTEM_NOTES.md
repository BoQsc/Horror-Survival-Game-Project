# Prefab System Notes

## Current Implementation
- Captures building blocks only (from `building_manager`)
- Excludes terrain and terrain modifications by default
- Placement modes: **Surface** (on top of terrain) or **Carve** (buried 1 block with terrain carved)
- Note: Future enhancement planned for automatic submerge mechanics based on prefab structure

## Future Enhancements

### Terrain Capture Support
When needed, extend the prefab capture system to support:

1. **Unfiltered Capture** — Includes everything:
   - Building blocks (`building_manager.chunks`)
   - Terrain modifications (`chunk_manager.stored_modifications`)
   - Optionally: base terrain density values

2. **Filtered Capture** — Current behavior:
   - Building blocks only
   - No terrain data

3. **Toggle/Filter Options**:
   - `include_terrain_mods: bool` — Include player terrain edits (digging/filling)
   - `include_base_terrain: bool` — Include procedural terrain (for perfect reproduction)
   - `include_objects: bool` — Include placed .tscn objects (doors, tables)

4. **File Naming Convention**:
   ```
   prefabs/
   ├── watchtower.json           # Filtered (preferred if both exist)
   └── watchtower_full.json      # Unfiltered with terrain
   ```

5. **Load Priority**:
   - Check for filtered version first (`<name>.json`)
   - Fall back to unfiltered if filtered doesn't exist
   - Allow explicit override in spawn call

### Use Cases for Terrain Capture
- Pre-made bases with excavated foundations
- Cave hideouts with carved interiors
- Landscaped areas (flattened ground, trenches)
- Perfect reproduction of hand-crafted locations
