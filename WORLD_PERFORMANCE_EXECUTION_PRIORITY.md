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
| 8. Proof sweeps and cleanup | in progress | Validate cold, warm, revisit, edit, memory, frame-time, and idle-power behavior. |

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
- signed terrain setting changes and world-definition switches clear queued
  async disk artifact writes so stale artifacts are not persisted after an
  artifact signature change
- configurable startup preheat radius and policy, with collision-safe center
  readiness separated from optional wider background preheat
- central `WorldStartupCoordinator` autoload with weighted monotonic progress,
  stage monitoring, completion, failure, cancellation, and supersession state
- coordinator snapshots now expose the active stage label, stage-local progress,
  completed/total counts, and last stage details directly, so UI/proof code can
  report what is happening without rescanning manager internals
- loading UI driven by the coordinator contract, including late attachment,
  visible failure, and visible cancellation state
- loading UI snapshots and the default overlay now include a compact stage
  detail line with current stage percentage, work counts, and pending/blocking
  summaries while keeping progress trace events bounded
- stable startup readiness snapshots for terrain, prefab spawning, building
  application, vegetation, and entities, with coordinator-first consumption and
  loading-screen fallback support
- town-stall snapshots now derive `startup_readiness_verdict` from loading UI
  and `WorldStartupCoordinator` telemetry, including completion state, active
  loading/failure/cancellation flags, playable-ready state, completed/missing
  stage counts, elapsed startup time, slowest stage duration, and trace event
  count
- startup readiness verdicts and analyzer reports now preserve current stage
  label, stage-local progress, completed/total counts, compact detail text, and
  current stage details so failed production proof can point at the active
  blocker instead of only reporting incomplete startup
- startup readiness analyzer gates and town-stall runner proof gates now append
  a compact active-stage diagnostic only when startup proof fails, including the
  current stage, stage-local progress, work counts, and blocking detail when
  present
- terrain startup readiness snapshots now break pending work into artifact
  restores, generation misses, CPU mesh work, finalization nodes, visual-batch
  worker work, spawn-zone preheat, and async disk artifact write backlog, so the
  loading UI can explain terrain startup without scanning private queues
- terrain startup readiness details now also include session artifact cache and
  disk artifact cache hit/miss/store/restore/byte-budget counters, allowing warm
  startup proof to distinguish cache reuse from generated misses in the loading
  stage detail
- bounded world-map preview colorization and progressive low-resolution
  full-world preview generation
- native GDExtension height/biome generation with focused reference-output and
  timing validation
- worker-safe native height/biome generation that avoids Godot `Resource`
  allocation inside GDExtension worker calls by using the same header-only
  FastNoiseLite implementation Godot wraps, isolated as a documented
  third-party exception under `addons/third_party/fast_noise_lite`
- world-map full-bake proof telemetry with stable image, metadata, and combined
  content signatures, stage timing, backend, layer validation, and export cache
  signature reporting
- town-stall snapshots, runner gates, analyzer gates, and raw-baseline proof
  propagation now expose world-bake proof for production bake timing,
  determinism, backend, and export validation
- aggregate and maximum GPU generation, sync, meshing dispatch, meshing sync,
  and mesh readback telemetry for the remaining cache-miss decision gate
- terrain process loop can sleep after sustained idle when there is no stream,
  generation, finalization, collision, visual batch, or spawn-zone work
- terrain process wake hooks for queued generation, completed generation,
  terrain edits, visual batch work, collision work, spawn-zone requests, and
  explicit player movement signals, with low-rate fallback polling retained for
  vehicles and custom viewers
- terrain runtime render-distance, collision-distance, and signed generation
  setting setters wake sleeping terrain immediately, invalidate stale stream
  keys or artifact signatures where needed, clear stale session artifacts, and
  expose bounded setting-change telemetry
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
- town-stall proof snapshots now sample those cached monitors and summarize
  `stationary_runtime_idle_verdict`, including idle ratio, busy samples,
  maximum pending work, maximum awake-process count, and per-subsystem awake
  blockers
- the same proof snapshots summarize terrain artifact cache behavior through
  `stationary_terrain_artifact_cache_verdict`, including ending hit ratio,
  entry count, memory and disk byte-budget ratios, eviction deltas, and disk-hit
  delta for warm/revisit and memory-pressure runs
- bounded vegetation placement artifact reuse with settings signatures and dirty
  terrain invalidation
- bounded scene-keyed entity pooling for non-permanent despawns
- work-aware entity maintenance timer and physics-process selection so inactive
  work categories do not force their faster update rate
- building, vegetation, and entity movement-signal wake paths with slower
  fallback polling for viewer-dependent work
- entity startup readiness now separates collision-relevant startup spawn work
  from background procedural spawn backlog, exposing both `startup_pending_total`
  and `background_spawn_backlog`
- entity spawn backlog now stays background-only when it is outside the
  collision-relevant viewer area and a viewer movement signal is connected, so
  it does not keep entity maintenance awake while stationary
- world-content loading messages and town-stall wait logs now name the blocking
  subsystem and include entity startup/backlog counters instead of hiding them
  behind a generic world-content total
- executable priority proof-suite wrapper in
  `addons/tests/run_world_performance_priority_proof.py`, which runs the fast
  Godot/Python contract checks and can optionally launch a heavy production raw
  town baseline with startup, world-bake, runtime-idle, and terrain-cache proof
  gates enabled
- the fast proof-suite wrapper now includes foundational contracts for session
  terrain artifact cache eviction/invalidation, disk artifact stale/corrupt
  fallback, startup preheat readiness policy, terrain process sleep/wake,
  runtime setting wake/signature invalidation, vegetation placement cache reuse,
  entity pool reuse, work-aware entity maintenance cadence, and
  player/building/vegetation/entity viewer-position wake signals
- the same wrapper now includes focused native/helper contracts for terrain
  height-map sampling, world-map road/water mask sampling, terrain mask sample
  telemetry, building grouped mesh merge, vegetation cluster render payloads,
  vegetation native record append, vegetation noise samples, pending chunk
  scheduling, removed-entry filtering, and generation timing telemetry
- the proof wrapper now validates its planned steps before execution so fast
  Godot steps must remain focused `addons/tests/*_test.gd` contracts or
  editor parse checks, while bot/gameplay harness scripts and raw town launchers
  are rejected unless they are explicit heavy production steps
- proof reports now include `completion_audit`, which keeps `complete=false`
  until accepted heavy production proof, threshold tuning, GPU sync/readback A/B
  evidence, and rollout/test-hook cleanup are all resolved; the audit separates
  raw-case-covered scenarios from contract-only scenarios so dry-run planning
  cannot be mistaken for production acceptance
- static readiness audit in
  `addons/tests/audit_world_performance_priority_readiness.py`, which validates
  the non-game production proof plan, records current fast/dry-run report state,
  and inventories source-side rollout/test hooks that must be removed or
  permanently classified after accepted production captures; the cleanup queue
  includes post-evidence actions for removal/review candidates versus tuning
  overrides that should become defaults or documented project settings
- the proof-suite wrapper now expands a named `priority_full` production suite
  into runtime default, unchanged-revisit, and render-distance 5/10/15 raw
  baseline cases, and writes roadmap scenario coverage plus missing externally
  prepared scenarios into dry-run and production JSON reports
- the proof-suite wrapper now includes the bounded world-map preview builder
  contract and counts low-resolution preview as contract-covered in production
  plan JSON when Godot contract checks are included
- the proof-suite wrapper now counts warm startup as contract-covered through
  `terrain_warm_startup_preheat_test.gd`, which verifies a disk-seeded startup
  preheat queues spawn terrain as artifact restores with no generation misses
- the proof-suite wrapper now includes the terrain world-definition change
  contract and counts world-switch cache isolation as contract-covered when
  Godot contract checks are included; the contract verifies stale terrain
  artifacts, pending disk writes, and queued generation are cleared on world
  switch
- the proof-suite wrapper now counts dirty edit revisit as contract-covered
  through `terrain_generation_telemetry_test.gd`, which verifies completed
  terrain edits refresh session artifacts and revisit through artifact restore
  instead of first-revisit generation
- the proof-suite wrapper now counts modified-terrain save/reload as
  contract-covered through `save_manager_terrain_modifications_test.gd`, which
  verifies terrain load clears live chunks before restoring saved edit payloads
- raw town-stall baseline cases now include `priority_revisit` plus
  `priority_render_distance_5`, `priority_render_distance_10`, and
  `priority_render_distance_15`, with their repeat-entry/render-distance env
  overrides captured in run JSON
- raw town-stall baseline cases now also include `priority_memory_pressure`,
  which reduces terrain artifact memory/disk budgets through explicit
  TerrainManager artifact-cache budget env overrides applied by the harness
- the proof-suite wrapper defaults heavy runs to production `proof` mode and
  rejects contaminated-idle overrides, disabled temperature gates, or non-native
  world-bake backends unless explicitly marked as `pilot`
- third-party policy check that keeps non-CC0 code isolated to approved
  `addons` third-party roots with source, license, and reason documented

## Validation

Godot `4.6.3` validation:

- `addons/tests/world_event_trace_test.gd`: pass
- `addons/tests/save_load_trace_test.gd`: pass
- `addons/tests/loading_screen_progress_test.gd`: pass
- `addons/tests/terrain_startup_readiness_detail_test.gd`: pass
- `addons/tests/terrain_warm_startup_preheat_test.gd`: pass
- `addons/tests/terrain_artifact_cache_test.gd`: pass
- `addons/tests/terrain_artifact_disk_store_test.gd`: pass
- `addons/tests/terrain_artifact_disk_write_queue_test.gd`: pass
- `addons/tests/terrain_generation_telemetry_test.gd`: pass
- `addons/tests/save_manager_terrain_modifications_test.gd`: pass
- `addons/tests/world_performance_monitors_test.gd`: pass
- `addons/tests/town_stall_monitor_snapshot_test.gd`: pass
- `addons/tests/town_stall_artifact_budget_override_test.gd`: pass
- `addons/tests/terrain_runtime_setting_wake_test.gd`: pass
- `addons/tests/terrain_world_definition_change_test.gd`: pass
- `addons/tests/terrain_process_sleep_test.gd`: pass
- `addons/tests/player_viewer_signal_test.gd`: pass
- `addons/tests/terrain_startup_preheat_test.gd`: pass
- `addons/tests/world_startup_coordinator_test.gd`: pass
- `addons/tests/world_startup_readiness_snapshot_test.gd`: pass
- `addons/tests/world_map_preview_builder_test.gd`: pass
- `addons/tests/world_map_bake_proof_test.gd`: pass
- `addons/tests/world_map_height_biome_native_test.gd`: pass
- `addons/tests/world_map_height_biome_thread_policy_test.gd`: pass
- `addons/tests/vegetation_chunk_placement_cache_test.gd`: pass
- `addons/tests/entity_pool_reuse_test.gd`: pass
- `addons/tests/entity_maintenance_driver_test.gd`: pass
- `addons/tests/entity_viewer_signal_test.gd`: pass
- `addons/tests/entity_startup_readiness_snapshot_test.gd`: pass
- `addons/tests/entity_background_spawn_idle_test.gd`: pass
- `addons/tests/building_viewer_signal_test.gd`: pass
- `addons/tests/vegetation_viewer_signal_test.gd`: pass
- `addons/tests/vegetation_generation_timing_telemetry_test.gd`: pass
- `addons/tests/vegetation_harvest_render_refresh_test.gd`: pass
- `addons/tests/vegetation_tree_chop_render_refresh_test.gd`: pass
- `addons/tests/terrain_mask_sample_telemetry_test.gd`: pass
- `addons/tests/terrain_mesh_duplicate_telemetry_test.gd`: pass
- headless editor parse: pass, with the existing headless VulkanGuard warning

Python analyzer validation:

- `addons/tests/analyze_performance_snapshot_verdict_test.py`: pass
- `addons/tests/analyze_raw_baseline_proof_test.py`: pass
- `addons/tests/run_town_stall_snapshot_gate_test.py`: pass
- `addons/tests/run_town_stall_raw_baseline_proof_test.py`: pass
- `addons/tests/run_world_performance_priority_proof_test.py`: pass
- `addons/tests/audit_world_performance_priority_readiness_test.py`: pass
- `addons/tests/audit_world_performance_priority_readiness.py --output .agent/world-performance-priority-readiness-audit.json`: pass
- `addons/tests/analyze_performance_snapshots.py --help`: pass
- `addons/tests/run_town_stall_raw_baseline.py --help`: pass
- `addons/tests/run_world_performance_priority_proof.py --help`: pass
- `addons/tests/run_world_performance_priority_proof.py --output .agent/world-performance-priority-proof-fast.json`: pass
- `addons/tests/run_world_performance_priority_proof.py --output .agent/world-performance-priority-proof-fast-after-entity-startup.json`: pass
- `addons/tests/run_world_performance_priority_proof.py --output .agent/world-performance-priority-proof-fast-after-entity-idle.json`: pass
- `addons/tests/run_world_performance_priority_proof.py --output .agent/world-performance-priority-proof-fast-after-startup-failure-context.json`: pass
- `addons/tests/run_world_performance_priority_proof.py --dry-run --run-production --output .agent/world-performance-priority-proof-production-plan-dry-run.json`: pass
- `addons/tests/run_world_performance_priority_proof.py --output .agent/world-performance-priority-proof-fast-after-production-plan.json`: pass
- `addons/tests/run_world_performance_priority_proof.py --output .agent/world-performance-priority-proof-fast-after-memory-pressure-plan.json`: pass
- `addons/tests/run_world_performance_priority_proof.py --output .agent/world-performance-priority-proof-fast-after-preview-plan.json`: pass
- `addons/tests/run_world_performance_priority_proof.py --output .agent/world-performance-priority-proof-fast-after-world-switch-plan.json`: pass
- `addons/tests/run_world_performance_priority_proof.py --output .agent/world-performance-priority-proof-fast-after-edit-save-plan.json`: pass
- `addons/tests/run_world_performance_priority_proof.py --output .agent/world-performance-priority-proof-fast-after-warm-start-plan.json`: pass
- `addons/tests/run_world_performance_priority_proof.py --output .agent/world-performance-priority-proof-fast-after-foundation-contracts.json`: pass
- `addons/tests/run_world_performance_priority_proof.py --output .agent/world-performance-priority-proof-fast-after-native-helper-contracts.json`: pass
- `addons/tests/run_world_performance_priority_proof.py --output .agent/world-performance-priority-proof-fast-after-safety-guard.json`: pass
- `addons/tests/run_world_performance_priority_proof.py --output .agent/world-performance-priority-proof-fast-after-completion-audit.json`: pass
- `addons/tests/run_world_performance_priority_proof.py --output .agent/world-performance-priority-proof-fast-after-readiness-audit.json`: pass
- `addons/tests/run_world_performance_priority_proof.py --output .agent/world-performance-priority-proof-fast-after-cleanup-action-audit.json`: pass
- `addons/tests/run_world_performance_priority_proof.py --dry-run --output .agent/world-performance-priority-proof-safety-dry-run.json`: pass
- `addons/tests/check_godot_launcher_safety.py`: pass
- `addons/tests/check_third_party_policy.py`: pass

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

Two June 4, 2026 heavy diagnostic attempts are also rejected as production
evidence. The native-backend attempt crashed before the hold window; the useful
follow-up was making the native height/biome GDExtension path worker-safe
without allocating Godot `Resource` objects in the worker. A second fallback
`gdscript` bake attempt got past generation but never reached the hold window:
terrain, buildings, prefabs, and vegetation were ready while loading remained in
world-content stage on entity spawn backlog. That run was hot/contaminated and
used a fallback backend, so it is diagnostic only. It identified the startup
readiness bug fixed in the current slice.

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
- automated startup readiness proof through `startup_readiness_verdict`, which
  fails if loading is still active, startup failed or cancelled, playable-ready
  did not fire, expected stages are incomplete or missing, or configured timing
  and trace thresholds are exceeded
- automated world-bake proof through `world_bake_proof`, which records full
  bake stage timings, height/biome backend, expected baked layers, stable image
  and metadata signatures, combined content signature, hash cost, save/export
  timing, and export cache signature
- live debugger/test-harness visibility through cached
  `WorldPerformanceMonitors` custom monitors
- stationary proof harness visibility through `stationary_runtime_idle_verdict`,
  `stationary_terrain_artifact_cache_verdict`, and window-level monitor
  summaries
- automated snapshot analysis gates for latest production startup readiness,
  world-bake proof, stationary runtime idle, and terrain artifact cache reuse
  verdicts
- opt-in town-stall runner proof gates through
  `TOWN_STALL_REQUIRE_STARTUP_READINESS_PROOF`,
  `TOWN_STALL_REQUIRE_WORLD_BAKE_PROOF`,
  `TOWN_STALL_REQUIRE_RUNTIME_IDLE_PROOF`, and
  `TOWN_STALL_REQUIRE_TERRAIN_ARTIFACT_CACHE_PROOF`, so production proof runs
  can fail immediately when startup readiness is incomplete, world bake/export
  proof is missing or over budget, stationary runtime work remains awake, or
  warm artifact reuse, budget compliance, or eviction churn is not visible
- raw town-stall baseline proof flow through CLI flags that pass those gates to
  child town runs, record the active proof-gate environment in JSON, and
  aggregate startup, bake, idle, reuse, budget, and eviction proof values per
  case
- analyzer raw-baseline proof gates that preserve and enforce the latest raw
  proof verdicts from repeated town-stall baseline JSON
- one executable proof-suite entry point that can run local smoke checks or the
  heavy production proof flow and persists a JSON report under `.agent`
- true GPU cache-miss batch, synchronization, and readback cost through aggregate
  and maximum terrain telemetry
- dependent-system reuse and movement wake behavior through vegetation, entity,
  and building telemetry
- entity startup proof can distinguish immediate spawn blockers from background
  procedural spawn backlog, so loading UI and production gates do not confuse
  event-driven runtime work with required startup work
- runtime idle proof can ignore background-only entity spawn backlog when the
  entity maintenance driver is asleep and no collision-relevant spawn queue work
  is actionable

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
The non-game contract tests now also prove that signed setting changes and
world-definition switches drop stale queued disk artifact writes before they can
be persisted under an old signature.

Priority 3 is in progress. `WorldStartupCoordinator` now owns weighted monotonic
progress, monitored manager stages, completion, failure, cancellation, and
supersession state, the loading UI consumes that contract, and
`WorldPerformanceMonitors` exposes cached custom monitors for live startup and
runtime work state. Terrain, prefab, building, vegetation, and entity managers
now expose stable startup readiness snapshots consumed by the coordinator and
loading-screen fallback path. Town-stall snapshots, runner gates, analyzer
gates, and raw-baseline proof propagation now expose startup-readiness proof.
Entity readiness now treats distant procedural spawn plans as visible background
work instead of startup-blocking work, while collision-relevant pending spawns
and near deferred chunks can still block release.
Remaining work is proving the production cold, warm, failure, and world-switch
flows with those gates enabled.

Priority 4 is in progress. Preview colorization is bounded, a progressive
low-resolution full-world preview exists, and height/biome generation has a
worker-safe native GDExtension backend with focused timing and reference-output
validation. The native worker path uses the same FastNoiseLite implementation
Godot wraps, isolated under `addons/third_party/fast_noise_lite` as a narrow
license exception so project-owned code remains CC0.
The generator and proof harness now expose full-bake stage timing,
deterministic content signatures, layer validation, and export signatures.
Remaining work is capturing production full-bake runs with those gates enabled
and only then deciding whether any measured layer warrants a compute-shader
backend.

Priority 5 is in progress. Aggregate and maximum synchronization and readback
telemetry is now available for true GPU generation batches. Asynchronous
readback is not enabled yet; it remains a measured A/B experiment because it can
increase latency and buffer-lifetime complexity without reducing transfer cost.

Priority 6 is in progress. Terrain can sleep its per-frame process loop and wake
from internal work or explicit player movement. Buildings and vegetation also
use player movement signals for their relevant refresh paths, and entities use
the same signal to wake viewer-dependent spawn, dormant-respawn, and balanced
fill maintenance. Far entity spawn backlog no longer keeps the maintenance
timer awake when a viewer movement signal is connected; movement into the
relevant area wakes the spawn queue. Terrain render-distance,
collision-distance, terrain-height,
water-level, noise-frequency, and procedural-road setting changes also wake the
terrain process directly, refresh signed artifact settings, and are counted in
telemetry. Save-load world definition changes now flow through the terrain
setter, clear stale queued work, reload world-map GPU state, and notify
dependent caches. `WorldPerformanceMonitors`
now exposes aggregate pending work, awake-process count, and a cached idle verdict
for stationary proof runs, and the town-stall harness records those values in
per-sample, per-window, and top-level snapshot fields. Fallback polling remains
intentionally available for vehicles and custom viewers. Remaining work is
production stationary gameplay idle proof plus broader save-load and
memory-pressure proof.

Priority 7 is in progress. Vegetation placement has bounded chunk reuse and
dirty invalidation, entities have bounded scene-keyed pooling, and the existing
building chunk/prefab/payload caches preserve substantial static output across
visual unloads. Remaining work is runtime revisit proof, memory-pressure sweeps,
and any additional pooling justified by measurements.

Priority 8 is in progress. The proof-suite wrapper now consolidates the fast
contract checks and the optional heavy raw production proof run into one
executable command. Heavy runs now default to strict proof mode; contaminated or
fallback-backend diagnostics must be explicitly marked as pilot runs. The
default heavy `priority_full` suite now plans runtime default, unchanged revisit,
render-distance 5/10/15, and memory-pressure raw cases, and its dry-run JSON
reports which roadmap scenarios are covered by raw cases, which are covered by
contracts, and which are still externally prepared.
The fast suite
passed on June 5, 2026 and wrote:

```text
.agent/world-performance-priority-proof-fast.json
.agent/world-performance-priority-proof-fast-after-entity-startup.json
.agent/world-performance-priority-proof-fast-after-entity-idle.json
.agent/world-performance-priority-proof-fast-after-startup-failure-context.json
.agent/world-performance-priority-proof-production-plan-dry-run.json
.agent/world-performance-priority-proof-fast-after-production-plan.json
.agent/world-performance-priority-proof-fast-after-memory-pressure-plan.json
.agent/world-performance-priority-proof-fast-after-preview-plan.json
.agent/world-performance-priority-proof-fast-after-world-switch-plan.json
.agent/world-performance-priority-proof-fast-after-edit-save-plan.json
.agent/world-performance-priority-proof-fast-after-warm-start-plan.json
.agent/world-performance-priority-proof-fast-after-foundation-contracts.json
.agent/world-performance-priority-proof-fast-after-native-helper-contracts.json
.agent/world-performance-priority-proof-fast-after-safety-guard.json
.agent/world-performance-priority-proof-fast-after-completion-audit.json
.agent/world-performance-priority-proof-fast-after-readiness-audit.json
.agent/world-performance-priority-proof-fast-after-cleanup-action-audit.json
.agent/world-performance-priority-proof-safety-dry-run.json
.agent/world-performance-priority-readiness-audit.json
```

The fast run is not a substitute for production evidence. It proves gate wiring
and current contracts only. The current dry-run plan has no missing roadmap
scenarios: warm startup, edit revisit, modified-terrain save/reload, world
switch, and low-resolution preview are contract-only, while cold startup, cold
bake, revisit, render-distance, memory-pressure, frame-time, idle-power, and
stationary-idle coverage are planned through raw production cases. The
`completion_audit` block keeps the priority incomplete until the heavy
production proof flow passes with fresh captures, thresholds are tuned from
those captures, the GPU sync/readback A/B decision is made from accepted
cache-miss data, and temporary rollout hooks are removed. The readiness audit is
the current cleanup inventory: it validates the pre-production plan and lists
the rollout/test-hook candidates to classify only after accepted captures. Its
current non-game scan reports `125` cleanup candidates: `97` tuning overrides
to promote or document after evidence, `8` isolation hooks to remove or move
into harness-only code, and `20` `_for_test` markers to review.
