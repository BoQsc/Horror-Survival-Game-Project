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
