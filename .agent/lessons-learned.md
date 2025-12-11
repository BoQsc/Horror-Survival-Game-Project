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

## 🔧 TODO: Rectangular Rock Patches Near Roads (Dec 2024)

**Current Issue:** When roads cut through terrain at steep angles, the excavated walls sometimes show rectangular gray "rocky" texture patches. This is especially visible when standing on a high road looking down at plain terrain.

**Root Causes:**
1. **Material system** - Underground voxels exposed by road excavation get "stone" material ID (fixed with `effective_height` calculation)
2. **Cliff detection** - Steep slopes trigger rock texture in `terrain.gdshader` via `cliff_mix`
3. **Marching Cubes geometry** - Creates axis-aligned triangular faces at sharp density transitions

**Partial Fix Applied:**
- `gen_density.glsl` - Material depth now uses `effective_height` accounting for road excavation (helps but doesn't fix all cases)

**Future Solutions to Explore:**
1. Reduce cliff detection intensity near roads (tried 60%, caused shader conflicts)
2. Smoother density blending at road edges
3. Use biome/grass texture instead of rock for all road-adjacent steep slopes

**Files involved:** `gen_density.glsl`, `terrain.gdshader`
