# Technical Projection: Marching Cubes Evolution

This document outlines the "North Star" vision for the Marching Cubes implementation, aiming to bridge the gap between "Blobby organic terrain" and "Grid-locked structural predictability."

## 1. The "Solid State" Vision (Predictability)
The future of this terrain system is **Fundamental Predictability**.
- **Minecraft Mode as the Core**: Moving away from "floaty" density modifications to **Binary Occupancy**. A voxel is either Solid or Air. This eliminates the "density memory" issues where digging multiple times in the same spot produces inconsistent results.
- **Voxel-Perfect DDA Targeting**: Interaction rays will use **Digital Differential Analyzer (DDA)** voxel stepping to find the exact grid coordinate, completely bypassing mesh approximation artifacts.
- **Cardinal Normal Snapping**: In structural biomes (Roads, Buildings), surface normals will snap to 90/45 degree angles, giving the terrain a "hewn stone" or "crystalline" look that aligns with voxel aesthetics.

## 2. Command-Driven Architecture (Changeability)
Currently, terrain is a "flat" density buffer. The projection moves toward a **Non-Destructive Stack**.
- **Modification Command Buffer**: Chunks stop storing "final density" and instead store a **SDF Command List** (e.g., `Place Box at XID`, `Smooth Sphere at YID`).
- **Real-Time Re-Generation**: Because modifications are commands, we can "undo," "move," or "reorder" player actions by re-running the command buffer on the GPU.
- **World Serialization**: Save files will store the *Commands*, not the *Density*. This reduces save size from megabytes to kilobytes and allows the world to change version-to-version without breaking player builds.

## 3. Deep C++ Orchestration (Performance at Scale)
The GDExtension currently handles the "heavy lifting" (Meshing). The projection moves the **Brains** to C++.
- **Native Chunk Lifecycle**: Moving the `Dictionary` of 4000+ chunks into a native `std::vector` with **SIMD-optimized distance checks**. 
- **Multi-Isosurface Dithering**: Generating separate LODs or variations (Water vs Terrain) with a unified native manager to eliminate the physical " CHUNK_STRIDE" overlaps and replace them with mathematical continuity.
- **Binary SSBO Lookup**: Moving the currently hardcoded lookup tables into GPU Storage Buffers at runtime, allowing for hardware-specific optimizations and reduced shader compilation times.

## 4. Material-Driven Hardness (Visual Identity)
Terrain shouldn't all have the same "slope feel."
- **Variable Density Gradients**: Stone biomes will use steep gradients (Sharp edges), while Sand biomes use shallow gradients (Soft, rounded bumps).
- **Z-Bias Standards**: Enforcing the `FOUNDATION_OFFSET` (0.1m) across all tools to ensure player-placed items never flicker or Z-fight with the ground.
- **Structural Grammar**: Combining Cubes and Octahedrons (Manhattan SDFs) to provide a "Building Language" that feels natural to the grid.

## 5. Summary: From "Blob" to "Structure"
The technical projection transforms the current implementation from an organic sculpting toy into a **Robust Architectural Platform** where every voxel is a reliable, predictable building block.
