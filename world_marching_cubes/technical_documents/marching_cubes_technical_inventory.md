# Marching Cubes Technical Inventory

## 1. Core Orchestration (`ChunkManager.gd`)
- **Tri-Threaded Model**:
    - **Main Thread**: Manages lifecycle, scene tree integration, and visibility.
    - **Compute Thread**: Dedicated thread for `RenderingDevice` orchestration (prevents main thread GPU stalls).
    - **CPU Worker Pool**: Two (or more) dedicated threads for `MeshBuilder` (GDExtension) and `PhysicsServer3D` work.
- **Adaptive Loading**: Dynamically adjusts frame budget (1.0ms default) and `chunks_per_frame_limit` based on real-time FPS samples.
- **Time-Distributed Finalization**: Spreads chunk appearances over a 100ms interval to eliminate "popping" stutters.
- **Collision Proximity**: Physics bodies are only active/created within `collision_distance` (default: 3 chunks) to save CPU.

## 2. Generation Logic (Compute Shaders)
- **Grid Resolution**: 32x32x32 voxels per chunk, sampled at 33x33x33 points to provide the required 1-voxel overlap for seamless geometry.
- **`gen_density.glsl`**:
    - **Biome Distribution**: 2D fbm noise for Grass, Sand, Snow, Gravel, and Stone regions.
    - **Procedural Roads**: Networked 2D grid roads with height blending and edge smoothing.
    - **Underground**: Support for vertical layers (MIN_Y=-20 to MAX_Y=40), ore variations, and granite deposits.
- **`gen_water_density.glsl`**:
    - **Volumetric Isosurface**: Generates a separate high-performance water mesh using MC isosurface extraction.

## 3. Terrain Interaction (`modify_density.glsl`)
- **Shape Support**: 
    - **Sphere**: Smooth falloff-based additive density.
    - **Box**: Hard-edged cubic modification.
    - **Column**: Precise 1x1 vertical "fill/dig" for roads or terrain flattening.
    - **Diamond (Octahedron)**: Manhattan-distanced 45-degree slope generation.
- **Material System**: Writes persistent material ID data (Storage Buffer) to the terrain grid.
- **Persistence**: `stored_modifications` re-applies all player edits (SDF-style) whenever a chunk is regenerated from noise.

## 4. Meshing & Rendering (`marching_cubes.glsl`)
- **GPU Mesher**: Parallelized MC extraction using optimized lookup tables (currently hardcoded in `marching_cubes_lookup_table.glslinc` for stability).
- **GDExtension Integration**: Uses custom `MeshBuilder` and `ArrayMesh` for ultra-fast geometry construction from GPU data.
- **`terrain.gdshader`**:
    - **Tri-planar Mapping**: Seamless texturing on vertical and horizontal faces.
    - **PBR Blend**: Multi-source textures (Rock, Grass, Snow, Sand) blended by material ID and normal slope.
- **`water.gdshader`**: Volumetric transparency (Beer's Law) and depth-based color mixing (Shallow green to Deep dark teal).

## 5. Architectural Standards (Active & Proposed)
- **Chunk Stride**: Fixed at 31 (CHUNK_SIZE - 1) for perfect mesh continuity.
- **Zero-Fighting**: `FOUNDATION_OFFSET` (0.1m) documented as standard; implementation pending in core brushes.
- **Sync IDs**: `modification_batch_id` used to synchronize GPU modification finishes with CPU mesh updates.
