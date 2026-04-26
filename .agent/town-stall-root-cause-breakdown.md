# Town Stall Root Cause Breakdown

- Report: [town-stall-latest-report.md](C:/Users/Windows10_new/Documents/gpu-marching-cubes/.agent/town-stall-latest-report.md)
- Snapshot: [town-stall-latest-snapshot.json](C:/Users/Windows10_new/Documents/gpu-marching-cubes/.agent/town-stall-latest-snapshot.json)
- Date: 2026-04-26

## Read This First

The timers are nested. Parent scopes and child scopes overlap, so the child entries below are drill-downs, not extra time to add on top of the parent.

The stall breaks into five main groups:

1. Building collision generation is the biggest repeated cost.
2. Baked building payload application is the biggest bursty spike.
3. Terrain maintenance is a steady background cost with some collision-body work.
4. Entity scanning and respawn work is real but secondary.
5. Vegetation collider refresh and placement is distributed overhead.

## 1. Building Collision Generation

Effort to fix: High

This is the clearest recurring root cause.

- `building_chunk.generate_object_collision` - `1741.8ms` across `2462` calls
- `building.process.pending_object_collisions` - `409.5ms` across `424` calls
- `building.process_pending_object_collisions` - `365.2ms` across `424` calls
- `building.place_object` - `192.0ms` across `190` calls
- `building.apply_world_map_baked_building_payload.object_spawn_item` - `210.4ms` across `190` calls
- `building.place_object.chunk_place_object` - `80.1ms` across `190` calls
- `building_chunk.place_object` - `61.1ms` across `190` calls
- Counter: `building_chunk.trimesh_object_collisions_generated = 2462`

Likely cause:

The code is generating collision work very often, especially during object placement. The load is not one single bad function call, it is a repeated collision pipeline that is being hit thousands of times. That points to eager trimesh/collision creation, too much synchronous placement work, or both.

## 2. Baked Building Payload Application

Effort to fix: High to Medium-high

This is the biggest bursty spike path.

- `prefab_spawner.apply_world_map_baked_buildings` - `311.8ms` across `41` calls
- `prefab_spawner.apply_world_map_baked_buildings.apply_keys` - `285.5ms` across `41` calls
- `prefab_spawner.apply_world_map_baked_building_payload_for_key` - `284.3ms` across `14` calls
- `building.apply_world_map_baked_building_payload` - `283.1ms` across `9` calls
- `building.apply_world_map_baked_building_payload.object_spawns` - `222.9ms` across `9` calls
- `building.apply_world_map_baked_building_payload.apply_visual` - `41.9ms` across `9` calls
- `building.apply_world_map_baked_building_visual` - `41.2ms` across `9` calls
- `building.apply_world_map_baked_building_visual.mesh` - `36.1ms` across `9` calls

Likely cause:

A single baked building application fans out into chunk payload application, object spawning, and visual mesh setup. The worst spike is a specific building key that carried `21` object spawns and `4` chunk payloads. This looks like concentrated load-time work that should probably be split up or deferred.

## 3. Terrain Maintenance and Collision Bodies

Effort to fix: Medium

- `terrain.process` - `871.9ms` across `424` calls
- `terrain.process.update_chunks` - `81.0ms` across `83` calls
- `terrain.update_chunks` - `73.0ms` across `83` calls
- `terrain.update_chunks_native` - `65.0ms` across `83` calls
- `terrain.process.process_pending_nodes` - `93.0ms` across `83` calls
- `terrain.process_pending_nodes` - `84.5ms` across `83` calls
- `terrain.process_pending_nodes.finalize_item` - `69.9ms` across `81` calls
- `terrain.process.process_pending_terrain_collision_creates` - `155.2ms` across `424` calls
- `terrain.process_pending_terrain_collision_creates.create_body` - `104.3ms` across `30` calls
- `terrain.process.update_collision_proximity` - `89.4ms` across `424` calls

Likely cause:

Terrain has a steady per-frame upkeep cost, but the biggest isolated piece is collision body creation. The rest is spread across chunk updates and node finalization, so the issue here is more about cumulative maintenance than one dramatic hotspot.

## 4. Entity Scan, Respawn, and Spawn Queue

Effort to fix: Medium

- `entities.physics_process` - `414.7ms` across `522` calls
- `entities.physics_process.process_spawn_queue` - `125.5ms` across `74` calls
- `entities.process_spawn_queue` - `115.9ms` across `74` calls
- `entities.process_spawn_queue.scan` - `106.7ms` across `74` calls
- `entities.physics_process.update_entity_proximity` - `80.3ms` across `75` calls
- `entities.update_entity_proximity` - `64.3ms` across `75` calls
- `entities.update_entity_proximity.scan` - `38.8ms` across `75` calls
- `entities.physics_process.check_dormant_respawns` - `37.1ms` across `33` calls
- `entities.spawn_entity` - `42.7ms` across `34` calls

Likely cause:

The cost here is mostly scanning and checking state every frame, with spawning as a smaller follow-on cost. That makes this a candidate for throttling, caching, or reducing how often the scan runs.

## 5. Vegetation Collider Refresh and Placement

Effort to fix: Medium-low

- `vegetation.physics_process` - `685.7ms` across `522` calls
- `vegetation.physics_process.process_queued_collider_updates` - `125.5ms` across `522` calls
- `vegetation.physics_process.process_pending_placements` - `119.1ms` across `522` calls
- `vegetation.physics_process.refresh_colliders` - `57.9ms` across `48` calls
- `vegetation.place_grass_for_chunk` - `74.6ms` across `32` calls

Likely cause:

Vegetation is more distributed than the building path. It is still real overhead, especially around collider refresh and placement, but it reads more like recurring maintenance than a single dominating root cause.

## Priority Order

1. Reduce `building_chunk.generate_object_collision`.
2. Split or defer baked building payload application.
3. Trim terrain collision-body creation and pending-node work.
4. Throttle entity proximity and spawn-queue scans.
5. Rework vegetation collider refresh cadence.

## Practical Reading

If we want the shortest path to the real cause of the town stall, start with:

- object collision generation during building placement,
- baked building payload application,
- then terrain collision body creation.

Those three explain most of the visible pain in the report.
