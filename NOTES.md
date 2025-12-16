# GPU Marching Cubes - Developer Notes

## GPU Resource Cleanup (Building System)

**File:** `building_system/building_mesher.gd`  
**Toggle:** `ENABLE_GPU_CLEANUP` (line ~26)

### If you experience crashes during building/mesh generation:

1. Open `building_system/building_mesher.gd`
2. Find `const ENABLE_GPU_CLEANUP: bool = true`
3. Change to `false`
4. Test if crashes stop

### Background:
- The original code had GPU resource freeing disabled due to crashes
- We re-enabled it with correct freeing order (uniform_set first, then textures/sampler)
- Tested working on Godot 4.5 without crashes
- If crashes return, the freeing order may need more research

### Trade-off:
- **Cleanup ON:** No GPU memory leak
- **Cleanup OFF:** Leaks ~32KB per mesh generation (~3MB per 100 blocks placed)

---

## Slope-Based Cliff Rock Texture

**File:** `marching_cubes/terrain.gdshader`  
**Uniform:** `surface_cliff_threshold` (default: 10.0)

### What it does:
- Applies a rocky texture to steep surfaces (cliffs) based on surface normal angle
- Only active **above** `surface_cliff_threshold` Y level (default Y=10)
- Underground areas show raw materials (stone, ore, etc.) for gameplay clarity

### Potential Gameplay Issue:
> ⚠️ **FUTURE CONSIDERATION:** Players mining near the surface may not see the actual terrain materials (stone, ore, gravel) because the rocky cliff texture overlays them. This is purely visual enhancement and may need to:
> - Be reduced in intensity
> - Have the threshold lowered further
> - Be removed entirely if it causes confusion during early mining

### How to adjust:
1. **Change threshold:** Modify `surface_cliff_threshold` in the shader material (lower = less rocky texture near surface)
2. **Reduce intensity:** In the shader, find `cliff_mix` calculation and multiply by a value < 1.0
3. **Disable entirely:** Comment out the cliff rock blending section (lines ~190-198)

### Current behavior:
- Y > 12: Full rocky cliff texture on steep surfaces
- Y 8-12: Smooth transition zone
- Y < 8: No rocky texture (shows actual materials)
