# Bad Ideas Tested / Lessons Learned

This file documents optimization attempts and features that didn't work well, so we don't repeat them.

---

## ❌ Staggered Collider Updates (Dec 2024)

**Idea:** Update only 1 vegetation type per cycle (Trees → Grass → Rocks rotating) to spread CPU load.

**Problem:** If player stopped moving mid-cycle, some vegetation types never got colliders. Clicking on grass would do nothing because colliders weren't created yet.

**Lesson:** Collider updates must be predictable. All vegetation types should update together.

---

## ❌ Distance-Based Collider Skip (Dec 2024)

**Idea:** Only update colliders when player moves >3 units (skip when standing still).

**Problem:** Combined with staggered updates, this caused colliders to appear inconsistently. Player would enter an area and colliders wouldn't exist.

**Lesson:** Collider availability should not depend on movement history.

---

## ✅ What Works Instead

- Update ALL collider types every 15 physics frames (~0.25s at 60fps)
- Simple, predictable, reliable
- Small performance cost is worth the reliability

---

## Future Ideas to Test Carefully

| Idea | Risk | Notes |
|------|------|-------|
| LOD for distant chunks | Medium | Skip vegetation on far chunks |
| Merged MultiMeshes | Low | Fewer draw calls, more complex management |
| Object pooling | Low | Reuse mesh/collision resources |

---

## 🔧 TODO: Predictive Y-Layer Loading (Dec 2024)

**Current Issue:** When digging underground or building upward, the Y+/Y- chunk only loads WHEN you actually dig/place - causing a delay as the chunk generates.

**Desired Behavior:** Load adjacent Y-layer chunks BEFORE they're needed. For example:
- When player is near Y=0 digging downward, preload Y=-1 chunk
- When player is near Y=31 building upward, preload Y=1 chunk

**Implementation Ideas:**
1. Detect player Y position relative to chunk boundary
2. If within ~5 units of chunk boundary AND digging/building, preload adjacent Y chunk
3. Alternatively: always preload Y-1 when player is digging at Y < 5

**Files to modify:** `chunk_manager.gd` - `update_chunks()` function

---

## ✅ FIXED: Rectangular Rock Patches Near Roads (Dec 2024)

**Original Issue:** Rectangular gray "rocky" texture patches appeared on terrain near roads and underwater areas.

**Root Cause Found:**
The GPU material system (`marching_cubes.glsl`) sampled materials from an **integer voxel grid** using `round()`. All triangle vertices got the same material from the voxel center. Adjacent voxels with different materials created **hard rectangular boundaries**.

**Solution Implemented:**
Moved material detection from GPU (per-voxel) to **fragment shader (per-pixel)**:
- `terrain.gdshader` now calculates depth using world position + smooth noise
- Uses `smoothstep(10.0, 15.0, depth)` for soft grass→stone transition
- No grid sampling = no rectangular boundaries

**Files Modified:**
- `terrain.gdshader` - Per-pixel material detection using world position
- `chunk_manager.gd` - Added `terrain_height` and `noise_frequency` uniforms

**Key Insight:** Don't rely on discrete per-voxel data for smooth visual effects. Calculate continuous values in the fragment shader using world position.

---

## ⚠️ CRITICAL: Material Placement is a Fundamental Architecture Issue (Dec 2024)

**Problem:** Player-placed materials (sand, snow, etc.) don't display correctly at block boundaries, especially with small brush sizes. Spent extensive time debugging coordinate mismatches, sampling strategies, and radius extensions - none fully resolved it.

**Root Cause:**
The marching cubes mesh generation and material system have a fundamental mismatch:
1. Materials are stored at **discrete voxel positions** (3D texture)
2. Mesh surfaces exist at **interpolated positions** between voxels
3. Fragment shader samples materials at these interpolated positions
4. Boundary voxels may not have the correct material, causing artifacts

**Current Workaround:** Minimum brush radius of 1.5, dual voxel sampling, normal-biased sampling. Works for large placements, fails for small ones.

**LESSON FOR FUTURE DEVELOPMENT:**
> If rebuilding marching cubes terrain from scratch, **material placement must be designed FIRST**, not retrofitted. It's a fundamental architecture issue, not a shader fix.

**Better approaches to consider:**
1. **Vertex colors during mesh generation** - Assign materials in the GPU marching cubes shader when creating vertices, bake into mesh
2. **Per-triangle materials** - Store material per triangle face rather than per voxel
3. **Dual contouring** - Different isosurface algorithm with better material handling
4. **Hybrid approach** - Use block-based mesh (like building system) for player placements, marching cubes only for procedural terrain

**Files documenting this:** `MATERIAL_SYSTEM_LIMITATIONS.md` in root folder

---
