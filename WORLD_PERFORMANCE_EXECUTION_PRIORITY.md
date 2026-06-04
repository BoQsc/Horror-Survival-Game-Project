# World Performance Execution Priority

This file tracks the implementation order for
`WORLD_STARTUP_AND_TERRAIN_PERFORMANCE_ROADMAP.md`.

The order is deliberate: eliminate repeated work before optimizing the remaining
cache misses, and measure each layer before adding the next one.

| Priority | Status | Deliverable |
|---|---|---|
| 0. Measurement and trace contract | complete | Structured cold, warm, revisit, and edit telemetry with bounded recent events and repeatable measurement windows. |
| 1. Session terrain artifact cache | in progress | Restore unchanged revisited chunks without density generation or marching cubes. |
| 2. Disk artifacts and spawn preheat | in progress | Restore eligible base-world terrain artifacts during warm startup and preheat the spawn radius. |
| 3. Startup coordinator and loading UI | in progress | Weighted startup stages, monotonic progress, readiness levels, and failure reporting. |
| 4. Generator preview and bake optimization | in progress | Low-resolution preview plus measured native or compute backends for full-resolution bake hotspots. |
| 5. GPU sync and readback experiment | in progress | A/B test asynchronous readback or in-flight buffering for remaining cache misses. |
| 6. Event-driven terrain coordination | in progress | Wake terrain work on movement, edits, settings, and queues, then sleep when idle. |
| 7. Dependent runtime reuse | in progress | Extend reuse to vegetation, buildings, prefabs, and entities. |
| 8. Proof sweeps and cleanup | pending | Validate cold, warm, revisit, edit, memory, frame-time, and idle-power behavior. |

## Completed Slices

Priority 0 is complete. The first Priority 1 slice is implemented and validated
for unchanged chunks on the native CPU meshing path.

Implemented:

- reusable thread-safe bounded event traces
- SaveManager load-stage timing and failure trace events
- terrain startup, compute setup, and world-map load trace events
- terrain generation, repeat-generation, discard, unload, and modification counters
- persistent initial-load measurement and bounded completed-window history
- public terrain measurement windows used by the existing town test harness
- focused trace, load-stage, and terrain-window tests
- configurable byte-budgeted and entry-limited session terrain artifact cache
- cache signatures and stored-modification version checks
- cache invalidation when a chunk receives a stored terrain modification
- refreshed session artifacts after successful edited-chunk rebuilds
- restoration of raw editable buffers and deferred mesh data through the
  existing finalization path
- cache hit, miss, store, eviction, invalidation, and restore telemetry
- runtime cache configuration sync before artifact lookup and storage
- loading screen creation before SaveManager load-step emission
- weighted and monotonic loading screen progress across save-load, terrain,
  world-content, vegetation, and complete stages
- bounded loading screen trace events, failure state, and loading telemetry
  snapshots in town-stall performance captures
- disk-backed base terrain artifact store keyed by world/settings signature and
  chunk coordinate
- warm disk restore path after session cache misses
- bounded per-world disk entry count and byte budget, corrupt artifact fallback,
  and disk cache telemetry
- bounded asynchronous disk artifact write queue so eligible artifact persistence
  does not run on the gameplay-critical terrain finalization path
- optional disk artifact write bandwidth cap with completed-byte and rate-limit
  wait telemetry
- disk persistence limited to startup/spawn preheat by default, with an export
  to allow runtime exploration writes when explicitly enabled
- configurable startup preheat radius and policy, with collision-safe center
  readiness separated from optional wider background preheat
- central `WorldStartupCoordinator` autoload with weighted monotonic progress,
  stage monitoring, completion, failure, cancellation, and supersession state
- loading UI driven by the coordinator contract, including late attachment,
  visible failure, and visible cancellation state
- stable startup readiness snapshots for terrain, prefab spawning, building
  application, vegetation, and entities, with coordinator-first consumption and
  loading-screen fallback support
- bounded world-map preview colorization and progressive low-resolution
  full-world preview generation
- native GDExtension height/biome generation with focused reference-output and
  timing validation
- aggregate and maximum GPU generation, sync, meshing dispatch, meshing sync,
  and mesh readback telemetry for the remaining cache-miss decision gate
- terrain process loop can sleep after sustained idle when there is no stream,
  generation, finalization, collision, visual batch, or spawn-zone work
- terrain process wake hooks for queued generation, completed generation,
  terrain edits, visual batch work, collision work, spawn-zone requests, and
  explicit player movement signals, with low-rate fallback polling retained for
  vehicles and custom viewers
- terrain runtime render-distance and collision-distance setters wake sleeping
  terrain immediately, invalidate stale stream keys where needed, and expose
  bounded setting-change telemetry
- terrain world-definition changes now use a public setter that clears stale
  terrain artifacts and queued generation, reloads world-map CPU/GPU state,
  wakes terrain work, and notifies dependent building, prefab, and vegetation
  caches
- player movement signal source has a small configurable threshold so downstream
  terrain, building, vegetation, and entity listeners do not receive sub-frame
  movement jitter
- terrain process sleep, resume, idle-frame, and idle-poll telemetry
- `WorldPerformanceMonitors` autoload with cached Godot custom monitors for
  startup state, terrain artifact caches, disk-write backlog, GPU sync/readback,
  runtime process wake state, aggregate pending work, awake-process count, and
  a cached runtime idle verdict
- bounded vegetation placement artifact reuse with settings signatures and dirty
  terrain invalidation
- bounded scene-keyed entity pooling for non-permanent despawns
- work-aware entity maintenance timer and physics-process selection so inactive
  work categories do not force their faster update rate
- building, vegetation, and entity movement-signal wake paths with slower
  fallback polling for viewer-dependent work

## Validation

Godot `4.6.3` validation:

- `addons/tests/world_event_trace_test.gd`: pass
- `addons/tests/save_load_trace_test.gd`: pass
- `addons/tests/loading_screen_progress_test.gd`: pass
- `addons/tests/terrain_artifact_cache_test.gd`: pass
- `addons/tests/terrain_artifact_disk_store_test.gd`: pass
- `addons/tests/terrain_artifact_disk_write_queue_test.gd`: pass
- `addons/tests/terrain_generation_telemetry_test.gd`: pass
- `addons/tests/world_performance_monitors_test.gd`: pass
- `addons/tests/terrain_runtime_setting_wake_test.gd`: pass
- `addons/tests/terrain_world_definition_change_test.gd`: pass
- `addons/tests/terrain_process_sleep_test.gd`: pass
- `addons/tests/player_viewer_signal_test.gd`: pass
- `addons/tests/terrain_startup_preheat_test.gd`: pass
- `addons/tests/world_startup_coordinator_test.gd`: pass
- `addons/tests/world_startup_readiness_snapshot_test.gd`: pass
- `addons/tests/world_map_preview_builder_test.gd`: pass
- `addons/tests/world_map_height_biome_native_test.gd`: pass
- `addons/tests/vegetation_chunk_placement_cache_test.gd`: pass
- `addons/tests/entity_pool_reuse_test.gd`: pass
- `addons/tests/entity_maintenance_driver_test.gd`: pass
- `addons/tests/entity_viewer_signal_test.gd`: pass
- `addons/tests/building_viewer_signal_test.gd`: pass
- `addons/tests/vegetation_viewer_signal_test.gd`: pass
- `addons/tests/vegetation_generation_timing_telemetry_test.gd`: pass
- `addons/tests/vegetation_harvest_render_refresh_test.gd`: pass
- `addons/tests/vegetation_tree_chop_render_refresh_test.gd`: pass
- `addons/tests/terrain_mask_sample_telemetry_test.gd`: pass
- `addons/tests/terrain_mesh_duplicate_telemetry_test.gd`: pass
- headless editor parse: pass, with the existing headless VulkanGuard warning

The focused script tests also print the existing project-autoload resource leak
warning during shutdown. Their assertions pass.

## Revisit Proof

A completed terrain-isolated repeat-entry run on June 3, 2026 used render
distance `5`, buildings disabled, entities disabled, and the stream-ready hold
gate disabled. The final `repeat_entry_second` measurement window reported:

| Metric | Value |
|---|---:|
| Window elapsed | 35,139.588 ms |
| Chunk generations | 220 |
| Repeat chunk generations | 218 |
| Discarded generations | 2 |
| Chunk unloads | 220 |
| Modification rebuilds | 0 |

Snapshot:

```text
.agent/town-stall-appdata/Godot/app_userdata/Horror Survival Game Project/debug/performance/snapshot_menu_2026-06-03_11-23-29.json
```

This was a work-count proof, not an FPS, wattage, or thermal baseline. The
machine preflight was contaminated and the GPU was hot. The result still
answers the Priority 1 decision: unchanged revisits are regenerating almost all
terrain chunks instead of restoring reusable artifacts.

A post-cache terrain-isolated repeat-entry run on June 3, 2026 used render
distance `3`, buildings disabled, entities disabled, and the stream-ready hold
gate disabled. The final `repeat_entry_second` measurement window reported:

| Metric | Value |
|---|---:|
| Window elapsed | 35,073.930 ms |
| Artifact restores | 139 |
| Artifact cache misses | 1 |
| Chunk generations | 1 |
| Repeat chunk generations | 1 |
| Discarded generations | 0 |
| Chunk unloads | 140 |
| Modification rebuilds | 0 |

The session cache held `137` artifacts using `94,499,328` bytes, or about
`17.6%` of its configured `512 MiB` budget. Across the complete run it avoided
`312` generations and reported no evictions, invalidations, skipped stores, or
discarded restores.

Snapshot:

```text
.agent/town-stall-appdata/Godot/app_userdata/Horror Survival Game Project/debug/performance/snapshot_menu_2026-06-03_11-52-05.json
```

The pre-cache and post-cache runs used different render distances, so they are
not an FPS comparison. The work-count ratio is still decisive: the pre-cache
second entry generated `220/220` unloaded chunks, while the post-cache second
entry generated `1/140` and restored `139/140`.

## Rejected Proof Attempt

An additional automated town-stall proof attempt on June 3, 2026 was rejected
by the existing clean-idle preflight before launch. It measured `100.0%` median
CPU load and `26.44 W` median GPU power, above the harness limits of `55.0%` and
`15.00 W`. No FPS, power, warm-start, or idle-power conclusion should be drawn
from that attempt.

## Decision Gate

The telemetry now answers:

- startup generation work through `terrain_initial_load_measurement`
- current and completed benchmark windows through terrain measurement snapshots
- repeated and discarded chunk generation through persistent counters
- terrain edit work through modification rebuild counters
- memory, disk, or uncached world definition loads through `world_map_load_profile`
- SaveManager stage duration and failure state through `load_trace`
- startup stage, readiness, failure, cancellation, and supersession state through
  `WorldStartupCoordinator`
- manager-specific startup readiness through stable
  `get_startup_readiness_snapshot()` snapshots consumed by the coordinator
- live debugger/test-harness visibility through cached
  `WorldPerformanceMonitors` custom monitors
- true GPU cache-miss batch, synchronization, and readback cost through aggregate
  and maximum terrain telemetry
- dependent-system reuse and movement wake behavior through vegetation, entity,
  and building telemetry

## Current Slice

Priority 1 remains in progress. The current cache is session-only and targets
the default native CPU meshing path. Main-thread mesh materialization still
runs on restore, and the GPU fallback meshing path remains uncached until
readback cost is measured. Successful edited-chunk rebuilds now refresh their
session artifacts so later unchanged revisits do not require an additional
generation.

Priority 2 is in progress. Warm startup can restore unmodified base terrain
artifacts from disk after a session-cache miss. Disk artifacts are bounded by
entry count and bytes and are persisted through a bounded write queue with an
optional bandwidth cap. Startup preheat has configurable radius and
require-before-play policy. Remaining work is measured warm-start proof, disk
budget and bandwidth sweeps, and tuning the production preheat policy.

Priority 3 is in progress. `WorldStartupCoordinator` now owns weighted monotonic
progress, monitored manager stages, completion, failure, cancellation, and
supersession state, the loading UI consumes that contract, and
`WorldPerformanceMonitors` exposes cached custom monitors for live startup and
runtime work state. Terrain, prefab, building, vegetation, and entity managers
now expose stable startup readiness snapshots consumed by the coordinator and
loading-screen fallback path. Remaining work is proving the production cold,
warm, failure, and world-switch flows.

Priority 4 is in progress. Preview colorization is bounded, a progressive
low-resolution full-world preview exists, and height/biome generation has a
native GDExtension backend with focused timing and reference-output validation.
Remaining work is authoritative full-bake timing, determinism/export proof, and
only then deciding whether any measured layer warrants a compute-shader backend.

Priority 5 is in progress. Aggregate and maximum synchronization and readback
telemetry is now available for true GPU generation batches. Asynchronous
readback is not enabled yet; it remains a measured A/B experiment because it can
increase latency and buffer-lifetime complexity without reducing transfer cost.

Priority 6 is in progress. Terrain can sleep its per-frame process loop and wake
from internal work or explicit player movement. Buildings and vegetation also
use player movement signals for their relevant refresh paths, and entities use
the same signal to wake viewer-dependent spawn, dormant-respawn, and balanced
fill maintenance. Terrain render-distance and collision-distance changes also
wake the terrain process directly and are counted in telemetry. Save-load world
definition changes now flow through the terrain setter, clear stale queued work,
reload world-map GPU state, and notify dependent caches. `WorldPerformanceMonitors`
now exposes aggregate pending work, awake-process count, and a cached idle verdict
for stationary proof runs. Fallback polling remains intentionally available for
vehicles and custom viewers. Remaining work is production stationary gameplay
idle proof and broader save-load/settings coverage.

Priority 7 is in progress. Vegetation placement has bounded chunk reuse and
dirty invalidation, entities have bounded scene-keyed pooling, and the existing
building chunk/prefab/payload caches preserve substantial static output across
visual unloads. Remaining work is runtime revisit proof, memory-pressure sweeps,
and any additional pooling justified by measurements.
