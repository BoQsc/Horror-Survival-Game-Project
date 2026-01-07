# Zombie Spawn Height - Known Issues & Future Improvements

**Date**: 2025-12-18  
**Status**: Partially Fixed (Workaround in Place)

## What Was Fixed

1. **Sky-falling bug** - Zombies no longer teleport to Y=50 and fall from the sky
   - Changed void safety in `zombie_base.gd` from teleporting to self-freezing
   
2. **Terrain clipping** - Zombies now spawn above terrain (with +1.5m offset)
   - Modified `entity_manager.gd` spawn logic

3. **Collision verification** - Entities spawn frozen and only unfreeze after raycast confirms collision is active

## Current Behavior

Zombies spawn **slightly above terrain** (1.5m offset) rather than exactly on the surface. They then fall and land on the terrain. This is a workaround, not the ideal solution.

## Ideal Future Solution

Wait longer for terrain collision to stabilize before spawning at the exact raycast hit point:

1. When raycast first hits terrain, store the Y position
2. Wait 2-3 physics frames for collision to fully register
3. Raycast again to verify the position is stable
4. Only then spawn at the exact `terrain_y + 0.1` (minimal offset)

This would eliminate the "spawning in air and falling" effect while preventing clipping.

## Prefab Spawning Considerations

The current system may NOT work well for spawning inside house prefabs:
- Raycast only detects terrain (layer 1) - won't hit house floors unless on same layer
- +1.5m offset could push zombies through ceilings

**Recommended approach for indoor spawns:**
- Use predefined spawn point markers in prefabs (known-good positions)
- Or create separate spawn logic for prefab interiors with smaller offset

## Related Files

- `entities/entity_manager.gd` - Spawn queue and respawn logic
- `entities/zombie_base.gd` - Void safety / self-freeze logic
- `marching_cubes/chunk_manager.gd` - Collision proximity management
