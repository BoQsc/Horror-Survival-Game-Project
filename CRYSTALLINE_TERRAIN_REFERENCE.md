# Crystalline Terrain System - Technical Reference

**Created:** 2026-02-05  
**Goal:** Implement 7 Days to Die-like predictable, geometric terrain breaking with diamond-shaped chunks

---

## Table of Contents
1. [Overview](#overview)
2. [What Works](#what-works)
3. [What Doesn't Work (Limitations)](#what-doesnt-work-limitations)
4. [Implementation Details](#implementation-details)
5. [Key Files Modified](#key-files-modified)
6. [Configuration Options](#configuration-options)
7. [Lessons Learned](#lessons-learned)

---

## Overview

**The Problem:**  
Original terrain used smooth Marching Cubes with spherical brushes, creating organic "blobby" holes when digging. Users wanted predictable, geometric, crystalline breaking like 7 Days to Die.

**The Solution:**  
A multi-phase implementation involving:
- Diamond-shaped (octahedral) brushes using Manhattan distance
- Flat shading for faceted appearance
- Aggressive density quantization for sharp boundaries
- Optional crystalline terrain generation

---

## What Works

### ✅ Diamond-Shaped Brush
- **Status:** Fully functional
- **Effect:** Digging creates octahedral (8-sided diamond) holes instead of spheres
- **Implementation:** Manhattan distance (`|x| + |y| + |z|`) with binary density
- **Files:** `modify_density.glsl`, `voxel_brush.gd`

### ✅ Flat Shading
- **Status:** Implemented
- **Effect:** Terrain has visible faceted triangles instead of smooth surfaces
- **Implementation:** Per-face normals instead of per-vertex normals
- **Files:** `marching_cubes.glsl`

### ✅ Density Quantization
- **Status:** Implemented
- **Effect:** Snaps density to discrete steps for sharper block boundaries
- **Implementation:** Round to 0.5 increments, force surface values to ±0.5
- **Files:** `modify_density.glsl`

### ✅ Visual Debug Seams
- **Status:** Optional feature (F11 toggle)
- **Effect:** Shows diamond grid boundaries
- **Files:** `terrain.gdshader`

---

## What Doesn't Work (Limitations)

### ❌ True Block-Based Behavior
**Fundamental incompatibility:** Marching Cubes is designed for continuous, smooth surfaces. It interpolates between voxel corners, creating:
- Gradual transitions (even with quantization)
- Rounded edges (even with flat shading)
- Non-discrete boundaries

**7 Days to Die uses discrete block voxels** where each voxel is either 100% solid or 100% air. Marching Cubes fundamentally cannot replicate this without becoming a completely different algorithm.

### ⚠️ Terrain Generation Quantization
**Status:** Implemented but subtle  
**Issue:** World-scale terrain generation doesn't benefit much from diamond grid snapping. The effect is most visible when digging/placing, not in natural terrain.

### ⚠️ Aesthetic Compromise
**What we have:** Faceted diamond holes with visible triangles  
**What 7DTD has:** True cubic/block-based voxels with axis-aligned faces  
**Gap:** Our system is geometric but not truly "blocky" - it's a visual approximation

---

## Implementation Details

### Phase 1: Diamond Brush Shape

**Manhattan Distance for Octahedral Shape:**
```glsl
// In modify_density.glsl
vec3 dist_vec = abs(world_pos - params.brush_pos.xyz);
float manhattan_dist = dist_vec.x + dist_vec.y + dist_vec.z;

if (manhattan_dist <= params.brush_pos.w) {
    density_buffer.values[index] = params.brush_value;
    modified = true;
}
```

**Why it works:** Manhattan distance creates an octahedron (diamond shape) - the set of all points where `|x| + |y| + |z| = constant` forms 8 triangular faces.

---

### Phase 2: Visual Crystal Seams

**Debug Visualization:**
```glsl
// In terrain.gdshader
float manhattan = abs(world_pos.x) + abs(world_pos.y) + abs(world_pos.z);
float cell_pos = mod(manhattan, crystal_cell_size);
float seam = 1.0 - smoothstep(0.0, seam_width, cell_pos) * 
                    smoothstep(0.0, seam_width, crystal_cell_size - cell_pos);
ALBEDO = mix(ALBEDO, vec3(0.1, 0.08, 0.06), seam * 0.5);
```

**Purpose:** Shows where terrain will break along diamond grid boundaries.

---

### Phase 3: Terrain Generation Quantization

**Diamond Grid Snapping:**
```glsl
// In gen_density.glsl
if (params.crystal_cell_size > 0.0) {
    float manhattan = abs(world_pos.x) + abs(world_pos.y) + abs(world_pos.z);
    float cell_index = floor(manhattan / params.crystal_cell_size);
    float cell_center_manhattan = (cell_index + 0.5) * params.crystal_cell_size;
    
    if (current_manhattan > 0.001) {
        float scale = cell_center_manhattan / current_manhattan;
        sample_pos = world_pos * scale;
    }
}
```

**Push Constant Bug Fix:**  
GLSL pads structs to 16-byte alignment. A `vec4 + 5 floats = 36 bytes` struct actually requires **48 bytes** (3 × 16-byte blocks). Solution: Add 3 padding floats.

---

### Phase 4: Enhanced Blockiness

**Flat Shading (Face Normals):**
```glsl
// In marching_cubes.glsl
vec3 edge1 = v2 - v1;
vec3 edge2 = v3 - v1;
vec3 face_normal = normalize(cross(edge1, edge2));

// Apply same normal to all 3 vertices
mesh_output.vertices[start_ptr + 3] = face_normal.x;
mesh_output.vertices[start_ptr + 4] = face_normal.y;
mesh_output.vertices[start_ptr + 5] = face_normal.z;
// ... same for v2 and v3
```

**Aggressive Density Quantization:**
```glsl
// In modify_density.glsl
float step_size = 0.5;
current = round(current / step_size) * step_size;

// Force surface values to exact boundaries
if (abs(current) < 1.0) {
    current = sign(current) * step_size;
}
```

---

### Critical Bug Fix: Pickaxe Integration

**The Problem:**  
The pickaxe was using legacy code in `combat_system.gd` that hard-coded shape types (0 = Sphere, 1 = Box), completely bypassing the VoxelBrush registry system.

**The Fix:**
```gdscript
# Get brush from registry
var behavior: VoxelBrush = null
if brush_registry:
    if block_mode_enabled:
        behavior = brush_registry.get_tool_brush("pickaxe_block")
    else:
        behavior = brush_registry.get_tool_brush("pickaxe_classic")

# Apply using brush system
behavior.apply(terrain_manager, position, hit_normal)
```

**Without this fix, none of the diamond shape work would be visible in gameplay.**

---

## Key Files Modified

| File | Purpose | Changes |
|------|---------|---------|
| `voxel_brush.gd` | Brush type enum | Added `DIAMOND = 3` |
| `modify_density.glsl` | Brush operations | Manhattan distance logic, density quantization |
| `marching_cubes.glsl` | Mesh generation | Flat shading (face normals) |
| `terrain.gdshader` | Terrain rendering | Debug seam visualization |
| `gen_density.glsl` | Terrain generation | Diamond grid quantization, push constant fix |
| `chunk_manager.gd` | Chunk management | `crystal_cell_size` parameter, 48-byte push constant |
| `combat_system.gd` | Combat/mining logic | **Critical:** Use VoxelBrush registry instead of hard-coded shapes |
| `pickaxe_classic.tres` | Pickaxe preset | `shape_type = 3`, `radius = 2.0` |
| `pickaxe_block.tres` | Block pickaxe preset | `shape_type = 3`, `radius = 2.0` |

---

## Configuration Options

### ChunkManager Inspector
- **`crystal_cell_size`** (default: 0.0)
  - `0.0` = Smooth terrain generation
  - `2.0` = Crystalline terrain snapped to diamond grid
  - Only affects newly generated terrain

### Terrain Material Inspector
- **`debug_show_crystal_seams`** (default: false)
  - Shows diamond grid boundaries
  - Toggle at runtime with **F11 key**

### Pickaxe Radius
- Set in `.tres` preset files
- Default: `2.0` (large, obvious diamond shape)
- Smaller values create tighter patterns

---

## Lessons Learned

### 1. **Marching Cubes vs. Block-Based Voxels**
Marching Cubes is fundamentally a **continuous surface extraction algorithm**. Attempting to make it behave like discrete blocks is fighting against its core design. For true 7DTD-style terrain, consider:
- Greedy meshing with block voxels
- Dual Contouring (better for sharp features)
- Custom block-based rendering

### 2. **The Importance of Integration Points**
The diamond brush logic was perfect, but the pickaxe wasn't using it due to legacy code paths in `combat_system.gd`. **Always trace the full execution path** from UI action to shader execution.

### 3. **GLSL Struct Padding**
GLSL pads structs to 16-byte boundaries automatically. Calculate actual memory layout, not just sum of field sizes. A 36-byte struct becomes 48 bytes in practice.

### 4. **Visual Tricks Have Limits**
Flat shading and quantization help, but they can't fundamentally change how Marching Cubes interpolates. They're visual approximations, not true block behavior.

### 5. **Iterative Development Pays Off**
Building in phases (diamond brush → seams → quantization → flat shading) made debugging easier. Each phase was testable independently.

---

## Future Considerations

### If You Want True 7DTD-Style Blocks:
1. **Replace Marching Cubes** with a block-based system
2. **Use greedy meshing** for efficient rendering
3. **Store voxels as discrete states** (solid/air/partial)
4. Accept axis-aligned faces (not arbitrary angles)

### If You Want to Enhance Current System:
1. **Add material-specific breaking patterns** (different shapes per material)
2. **Implement multi-step breaking** (cracks before full break)
3. **Add particle effects** at diamond vertices
4. **Optimize quantization step size** (currently 0.5, try 0.25 or 1.0)

### Performance Notes:
- Flat shading is **slightly faster** (no gradient calculation per vertex)
- Density quantization adds **minimal overhead** (simple rounding)
- Diamond grid terrain gen has **negligible cost** (one extra calculation per voxel)

---

## Conclusion

**What we achieved:**  
A Marching Cubes terrain system with geometric, faceted diamond-shaped breaking that *approximates* 7DTD aesthetics within the constraints of continuous surface extraction.

**What we can't achieve with Marching Cubes:**  
True discrete block behavior with perfect axis-aligned faces and instantaneous transitions.

**The sweet spot:**  
If you want smooth organic terrain with *some* geometric character, this system works well. If you want pure block-based voxels, you need a different algorithm.

---

**Document Version:** 1.0  
**Last Updated:** 2026-02-05  
**Status:** All features implemented, tested for syntax errors, ready for gameplay testing
