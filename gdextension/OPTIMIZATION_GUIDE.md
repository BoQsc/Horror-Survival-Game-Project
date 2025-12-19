# Godot GDExtension High-Performance Module

This module implements C++ optimizations for critical performance bottlenecks in the purely GDScript-based implementation of the Marching Cubes terrain system.

## 🚀 Why GDExtension?
We identified three major main-thread bottlenecks that caused frame stutters (50ms+ spikes) during chunk generation:

1.  **Mesh Building (`build_mesh`)**: Unpacking `PackedFloat32Array` into Godot's `ArrayMesh` format (vertex, normal, color arrays) in GDScript is slow due to Variant overhead.
2.  **Texture Generation (`create_material_texture`)**: Iterating 33³ (35,937) voxels to create a Texture3D byte array in GDScript takes ~15-20ms.
3.  **Collision Generation (`create_trimesh_shape`)**: Godot's built-in `mesh.create_trimesh_shape()` is slow for dense meshes because it re-parses the ArrayMesh.

By moving these to C++, we reduced overhead by **10-50x**.

## 🛠️ Building
Requirements:
- Python (for SCons)
- C++ Compiler (Visual Studio / GCC / Clang)

Run the build script:
```bash
cd gdextension
python build.py
```
This will compile the C++ source in `src/` and output binaries to `bin/`.

## 📚 API Usage (`MeshBuilder`)

The module registers a class `MeshBuilder` that you can instantiate in GDScript. It is stateless and efficient.

### 1. Fast Mesh Building
Replaces `SurfaceTool` or manual `ArrayMesh` construction.
```gdscript
var builder = ClassDB.instantiate("MeshBuilder")

# Input: PackedFloat32Array where every 9 floats = {px, py, pz, nx, ny, nz, r, g, b}
# Stride: 9
var mesh = builder.build_mesh_native(vertex_data, 9)
```

### 2. Fast 3D Texture Creation
Replaces nested loops for creating `ImageTexture3D`.
```gdscript
# Input: PackedByteArray of material indices
var tex = builder.create_material_texture(material_bytes, 33, 33, 33)
```

### 3. Fast Collision Shape
Replaces `mesh.create_trimesh_shape()`. Generates `ConcavePolygonShape3D` directly from raw vertex data, skipping Variant parsing.
```gdscript
# Input: Same vertex buffer as build_mesh_native
# Returns: Ref<ConcavePolygonShape3D>
var shape = builder.build_collision_shape(vertex_data, 9)
```

## ⚠️ Performance Comparison
| Operation | GDScript (Approx) | GDExtension (Approx) |
| :--- | :--- | :--- |
| Texture Gen | ~20 ms | < 0.1 ms |
| Collision Gen | ~50 ms | ~4 ms |
| Mesh Build | ~10 ms | ~1 ms |
| **Total Stutter** | **~80ms** | **~5ms** |

## 🕵️ Profiling & Debugging Strategy

To identify these bottlenecks, we used high-precision timing telemetry around suspect blocks of code on the Main Thread.

### How to Profile
Wrap the code block in timing logic:
```gdscript
var start_time = Time.get_ticks_usec()

# ... Suspect Code Block (e.g., create_trimesh_shape) ...

var duration = (Time.get_ticks_usec() - start_time) / 1000.0
if duration > 2.0: # Filter out fast frames to reduce spam
    print("Operation took: %.2f ms" % duration)
```

### Telemetry Used
1.  **Chunk Finalization (`chunk_manager.gd`)**:
    *   Measured `_finalize_chunk_creation`.
    *   **Result**: Identified spikes of 50-60ms when `create_trimesh_shape()` was called.
    *   **Fix**: Moved collision generation to `MeshBuilder.build_collision_shape`.

2.  **Vegetation Placement (`vegetation_manager.gd`)**:
    *   Measured `_place_vegetation_for_chunk`.
    *   **Result**: Identified spikes of 30ms.
    *   **Cause**: `get_terrain_height` was iterating through 60 chunks vertically for every tree (120,000 checks per frame).
    *   **Fix**: Implemented `get_chunk_surface_height` to scan only the local chunk (2,000 checks per frame).

### Success Metrics
*   **Target Frame Time**: 16.6ms (60 FPS).
*   **Acceptable Burst**: < 8-10ms (leaving room for other systems).
*   **Final Results**: Both operations now run in < 6ms combined, eliminating stutter.
