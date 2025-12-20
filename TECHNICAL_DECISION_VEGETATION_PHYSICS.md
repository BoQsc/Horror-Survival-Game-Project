# Technical Decision: Vegetation Physics Optimization Revert

**Date:** December 20, 2025
**Topic:** Vegetation Collider Optimization vs. Debuggability

## Context
We encountered significant frame time spikes (up to 100ms) during gameplay, which were traced back to the `VegetationManager`. specifically the physics processing.
Validation confirmed that the dynamic addition and removal of `StaticBody3D` nodes for thousands of vegetation items (trees, grass, rocks) was causing the bottleneck.

## Attempted Solution: PhysicsServer3D RIDs
We implemented an optimization that replaced the node-based collision system (`StaticBody3D`, `Area3D`) with direct `PhysicsServer3D` server calls (`body_create`, `area_create`).

**Benefits Observed:**
*   **Performance:** The physics spikes were effectively eliminated. Frame times stabilized.
*   **Overhead:** Reduced scene tree overhead significantly as thousands of nodes were removed.

**Drawbacks:**
*   **Debug Visibility:** Colliders created directly via `PhysicsServer3D` are **invisible** in the Godot Editor's debug mode ("Visible Collision Shapes"). This makes debugging gameplay issues (e.g., "Why can't I walk here?", "Why didn't this hit?") extremely difficult.
*   **Complexity:** The codebase requires manual management of RIDs, shapes, and resource lifecycles, which is more complex than standard Node management.

## Decision
**Revert to Node-based Colliders (`StaticBody3D` / `Area3D`)**

We decided to revert the optimization and standardise on the standard Godot Node-based system for the following reasons:
1.  **Debuggability is Priority:** At this stage of development, the ability to visually verify collisions (using "Visible Collision Shapes") is more critical than raw performance.
2.  **Maintainability:** Keeping the code simpler (Nodes) allows for faster iteration and debugging of gameplay mechanics (chopping, harvesting).

## Future Recommendations
If performance becomes a critical blocker again in the future:
1.  **Re-implement RID Approach:** The `PhysicsServer3D` implementation was proven to work.
2.  **Add Custom Debug Drawing:** If RIDs are used, a custom debug drawing system must be implemented (using `ImmediateMesh` or `RenderingServer`) to draw wireframes for the invisible physics shapes when debug mode is active. This would bridge the gap between performance and debuggability.
