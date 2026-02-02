# Terrain Standards & Technical Notes

## 1. Zero Z-Fighting Guarantee
**Problem:** Terrain surfaces flickering through building floors when both are at exactly the same Y-level.
**Solution:**
- We enforce a **Z-Bias** of `0.1m` (10cm) for all terrain flattening.
- **Rule:** Never flatten terrain to exactly `floor.y`. Always use `floor.y - FOUNDATION_OFFSET`.
- **Implementation:** `chunk_manager.gd` defines `const FOUNDATION_OFFSET = 0.1`.

## 2. Terrain Continuity (Preventing Cracks)
**Jargon:** "Seams" are visible gaps, holes, or cracks that appear between two adjacent chunks.
**Problem:** Cracks or "missing faces" appearing at chunk borders after digging/flattening.
**Cause:** Modifying terrain near a border (e.g., x=31.5) without updating the neighbor chunk (x=32.0).



## 3. Marching Cubes Stride
- **Standard:** `CHUNK_SIZE` is 32 voxels. `CHUNK_STRIDE` is 31.
- **Reason:** Chunks must overlap by 1 voxel to share density values for the isosurface generation. This overlap is crucial for seamless mesh transitions.
