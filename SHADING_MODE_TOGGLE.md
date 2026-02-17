# Shading Mode Toggle

## Usage

### In Godot Editor
1. Select the **ChunkManager** node in the scene tree
2. In the Inspector panel, find `Use Flat Shading` checkbox
3. **Check** to enable Flat Shstop to see the immediate effect *(toggle applies instantly to new chunks)*

### Runtime Behavior
- Changes take effect **immediately** for newly generated chunks
- Existing chunks retain their current shading
- To apply to all terrain: Toggle the setting, then move away and return to force chunk reload

## Shading Modes

### Flat Shading ✓ Recommended
- **Fixes texture spillover** on flat surfaces
- Sharp, faceted edges (low-poly aesthetic)
- One face normal per triangle
- Better GPU performance (1 cross product vs 3 gradient samples)

### Smooth Shading (Default)
- Gradient-based per-vertex normals
- Softer, more organic appearance
- May show texture bleeding artifacts on flat terrain

## Technical Details

**Implementation:**
- Flag passed via push constant (`params.chunk_offset.w`)
- Shader calculates normals conditionally at runtime:
  - **Flat**: `cross(edge1, edge2)` - geometric face normal
  - **Smooth**: `gradient(density)` - density field gradient

**Why Flat Mode Fixes Spillover:**
- Smooth shading uses density gradients which vary due to:
  - Floating-point precision
  - Noise function artifacts
  - Voxel grid aliasing
- Flat shading uses pure geometry (cross product):
  - Identical normal across entire triangle
  - No interpolation = no artifacts
  - Stable under all conditions

## Files Modified

- [`chunk_manager.gd`](file:///c:/Users/Windows10_new/Documents/gpu-marching-cubes/world_marching_cubes/chunk_manager.gd#L36-L38) - Added export variable
- [`chunk_manager.gd`](file:///c:/Users/Windows10_new/Documents/gpu-marching-cubes/world_marching_cubes/chunk_manager.gd#L1473-L1476) - Updated push constant
- [`marching_cubes.glsl`](file:///c:/Users/Windows10_new/Documents/gpu-marching-cubes/world_marching_cubes/marching_cubes.glsl#L27) - Updated push constant layout
- [`marching_cubes.glsl`](file:///c:/Users/Windows10_new/Documents/gpu-marching-cubes/world_marching_cubes/marching_cubes.glsl#L163-L208) - Added conditional normal calculation
