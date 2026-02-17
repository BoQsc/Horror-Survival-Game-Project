# Technical Bridge: Transitioning to Manhattan Solid-State Terrain

This document outlines the architectural "bridge" required to migrate the current Euclidean, additive density system to the future **Octahedron-Centric, Command-Driven Manhattan system**.

## 1. The SDF Migration Bridge
**Current**: `density += modification` (Additive)
**Goal**: `density = min(density, modification_sdf)` (SDF Composition)

- **Gap**: Transitioning without wiping player saves.
- **Bridge**: Implement a **Voxel Version Header**. Chunks with Version 1 (Current) use additive blending; Chunks with Version 2 (New) use SDF Union/Subtraction. New modifications to V1 chunks will force a conversion to V2.

## 2. The Manhattan Geometric Bridge
**Current**: `length(world_pos - brush_pos)` (Sphere/Euclidean)
**Goal**: `abs(dx) + abs(dy) + abs(dz)` (Octahedron/Manhattan)

- **Gap**: Changing the primary primitive changes the "look" of existing terrain.
- **Bridge**: Introduce the **"Octahedron Wrapper"**. Our new `VoxelBrush` resource will have a `geometric_space` property. 
    - Existing brushes stay Euclidean for compatibility.
    - New "Solid State" brushes default to Manhattan space. 
    - Procedural generation biomes (desert, snow) will gradually transition to Manhattan space as they are refactored.

## 3. The Server/Client Headless Bridge
**Current**: GDExtension tightly coupled to `RenderingDevice` (Requires GPU).
**Goal**: Headless Server Validation (CPU-only).

- **Gap**: Dedicated servers cannot run GPU compute shaders.
- **Bridge**: **Native Hybrid Meshers**.
    - Implement the Manhattan SDF logic as a pure C++ function in the GDExtension.
    - **Compute Implementation**: Runs on GPU for high-speed client-side meshing.
    - **Native Implementation**: Runs on Server-side CPU for authoritative collision and interaction validation.

## 4. The "Modularity" Bridge
**Current**: `ChunkManager.gd` is an 80KB "God Object".
**Goal**: Decoupled, command-driven architecture.

- **Gap**: The manager is too complex to refactor in one go.
- **Bridge**: **Component Extraction**.
    - **Step 1**: Extract `TerrainConfig` (Settings/Constants).
    - **Step 2**: Extract `TerrainModifier` (SDF Command logic).
    - **Step 3**: Move `active_chunks` tracking into the `TerrainGrid` GDExtension.
    - **Step 4**: Reduce `ChunkManager` to a pure "Orchestrator" that only routes signals between these components.

## 5. Summary of Transitional Phases
| Phase | Focus | Result |
| :--- | :--- | :--- |
| **P1: Modularity** | Extract Config/Modifier | Clean logic separation. |
| **P2: SDF Logic** | CSG in `modify_density.glsl` | Precise, non-blobby builds. |
| **P3: Manhattan** | Octahedron-first SDFs | 45-degree crystalline world. |
| **P4: Authority** | Headless C++ Fallback | Dedicated Server readiness. |
