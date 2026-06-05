# World Startup and Terrain Performance Roadmap

This roadmap follows the completed `WORLD_MAP_CACHING_ROADMAP.md` and complements
`WORLD_RUNTIME_REUSE_ROADMAP.md`.

It covers the next performance problem: reduce expensive world generation,
terrain generation, mesh creation, and startup work by doing each piece once,
reusing unchanged results, preheating critical content before player release,
and keeping gameplay work event-driven and bounded.

## Objective

The target runtime contract is:

- The full world definition is baked outside gameplay.
- Startup loads or restores reusable artifacts before the player is released.
- Unchanged terrain chunks are restored instead of regenerated.
- Terrain generation and marching cubes run only on cache misses or dirty chunks.
- Player edits invalidate only the affected chunks and dependent systems.
- Gameplay processes only queued work caused by movement, edits, settings changes,
  save/load, or cache misses.
- Loading UI reports real weighted stages and never hides a long-running step.
- Logging and telemetry are structured, bounded, and cheap enough to leave enabled.

## Executive Decision

The first optimization should be reuse, not a larger GPU rewrite.

The current terrain pipeline already has a compute shader density pass, native C++
marching cubes, worker threads, bounded main-thread finalization, render prewarm,
and extensive telemetry. A reusable terrain chunk artifact cache is now active
for the default native CPU meshing path, so unchanged revisits can restore
data-only output instead of rerunning generation and marching cubes. Remaining
work is proof, tuning, and coverage for paths that are not yet cache-backed.

The recommended order is:

1. Measure cold load, warm load, first exploration, and unchanged revisit separately.
2. Add a bounded session terrain artifact cache.
3. Add optional disk artifacts and spawn-zone preheat.
4. Add a startup coordinator, loading UI contract, and structured load trace.
5. Optimize the world map generator with low-resolution preview and measured
   native/GPU backends.
6. Revisit synchronous GPU readback only after cache misses are rare.
7. Make the remaining terrain coordinator work wake/sleep driven.
8. Extend the same reuse rules to vegetation, buildings, prefabs, and entities.

## Confirmed Current State

| Area | Confirmed behavior | Consequence |
|---|---|---|
| World definition bake | `world_map_generator/world_map_generator.gd` writes versioned PNG layers plus metadata, and the height/biome pass can run through a worker-safe native GDExtension backend. | The 4,194,304-pixel height and biome pass is now removed from the slow GDScript loop on native-capable builds; remaining bake hotspots should still be measured before adding compute paths. |
| Generator UI | `world_map_generator/world_map_generator_ui.gd` uses a bounded preview builder and supports progressive low-resolution full-world previews. | Preview work is no longer required to colorize the authoritative full-resolution map on the main thread. |
| Native bake dependency | The worker-safe native height/biome path uses the same header-only FastNoiseLite implementation that Godot wraps, isolated under `addons/third_party/fast_noise_lite` with its MIT notice retained. | This is a narrow third-party exception; project-owned code remains CC0 and additional third-party code should not be added unless a measured roadmap need justifies it. |
| World definition load | `world_map_data/world_map_data.gd` has a versioned in-memory LRU and disk cache. Runtime callers can share read-only data. | Baked map decode and duplicate work are already addressed. |
| Runtime density generation | `world_marching_cubes/chunk_manager.gd` creates a local `RenderingDevice`, compute pipelines, and per-chunk density/material buffers. | GPU compute is already used where it fits. |
| Runtime meshing | The default path reads density/material buffers back and calls the `MeshBuilder` GDExtension for marching cubes on CPU workers. | The pipeline is hybrid, and transfer/synchronization boundaries matter. |
| Runtime finalization | Worker output is queued and materialized into meshes, shapes, nodes, materials, and collision under frame budgets. | Main-thread work is already bounded, but it still repeats on revisits. |
| Chunk unload | `_unload_chunk()` frees live nodes and GPU buffers while eligible data-only terrain artifacts remain in bounded session or disk stores. | Unchanged revisits can restore generation output while live render and physics resources remain bounded. |
| Artifact write safety | Signed terrain setting changes and world-definition switches clear pending async disk artifact writes. | Disk persistence cannot quietly write stale artifacts after a signature-changing runtime event. |
| Runtime event handling | Terrain, buildings, vegetation, and entities consume a thresholded explicit player movement signal; terrain render, collision, signed generation-setting, and world-definition setters wake sleeping stream work; fallback polling remains for vehicles or custom viewers. | Stationary coordination work can sleep without giving up correctness for alternate viewers, runtime setting changes, or save-load world switches. |
| Loading UI | The loading screen consumes the `WorldStartupCoordinator` weighted monotonic stage contract, exposes active stage label/progress/counts/details, and its fallback path understands manager readiness snapshots. Terrain readiness snapshots break pending work into artifact restores, generation misses, CPU mesh work, finalization, visual-batch worker work, preheat, async disk write backlog, and terrain artifact cache hit/miss/store/restore state. | Startup progress, failure, cancellation, supersession, stage-local work, cache reuse state, and real pending/blocking work are visible through one owner without extra manager polling. |
| Load telemetry | Save-load, terrain, startup coordinator, cache, and GPU batch traces are structured and bounded. | Production and test captures can explain startup and cache-miss work without per-frame or per-chunk spam. |
| Prewarm | Terrain, buildings, vegetation, and entities use representative render resource prewarm, and terrain startup preheat has configurable radius and readiness policy. | Critical terrain can be prepared before player release while wider preheat remains optional background work. |
| Entity startup readiness | Entity readiness snapshots separate collision-relevant startup spawn work from distant procedural spawn backlog. | The loading UI can release the player when immediate play is ready while still exposing background spawn backlog telemetry. |
| Entity runtime idle | Distant spawn backlog is background-only when the viewer movement signal is connected and the backlog is outside the collision-relevant area. | Stationary gameplay does not keep entity maintenance awake just to recheck far spawn plans. |

## Measured Starting Point

The locked town baseline remains the performance guardrail:

| Metric | Baseline |
|---|---:|
| Average FPS | 59.946 |
| Hold power | 31.498 W |
| Stationary hold power | 31.529 W |
| Average frame | 16.682 ms |
| Maximum frame | 28.822 ms |
| Frames over 40 ms | 0 |
| Frames over 50 ms | 0 |

The locked artifact also reports a representative peak terrain generation event:

| Terrain step | Measured value |
|---|---:|
| GPU generation batch | 1.063 ms |
| GPU generation sync | 0.414 ms |
| GPU mesh readback | 0.621 ms |
| Native CPU mesh build | 3.488 ms |
| Pending node processing | 2.014 ms |
| Terrain finalization | 0.556 ms |
| Generation event ID | 742 |

The important observation is not that one chunk is catastrophically slow. It is
that the run reached 742 generation events. Avoiding repeated generation on
unchanged revisits is likely more valuable than reducing a single chunk by a
fraction of a millisecond.

## Design Rules

- Avoid work before making work faster.
- Cache data artifacts, not active scene nodes, as the default reusable format.
- Keep live render and physics resources bounded by render and collision distance.
- Keep cache size bounded by explicit memory and disk budgets.
- Never persist `RID` values. They are valid only for the owning rendering or
  physics device lifetime.
- Keep the scene tree main-thread owned. Worker threads should produce data-only
  results that the main thread materializes.
- Use GPU compute for uniform data-parallel work.
- Use native CPU code for branch-heavy layout, graph, and serialization work.
- Do not move a path to C++ or compute shaders without a before/after measurement.
- Do not make asynchronous readback a requirement until it proves better in this
  project. It changes latency and queueing behavior, not hardware bandwidth.
- Preserve determinism. The same world definition, generator version, settings,
  and modifications must produce the same artifact key and output.
- Invalidate the smallest correct region.
- Loading progress must be based on owned work counts or measured sub-progress,
  not guessed text transitions.
- Background spawn backlog must be visible but should not block player release
  unless it is within the collision-relevant startup area or strict proof mode
  intentionally asks for full spawn backlog completion.
- Background spawn backlog also should not count as active runtime pending work
  while the movement signal can wake it when the viewer approaches.
- Production logs must summarize stages and slow outliers, not print every chunk.

## Target Architecture

```text
World Map Generator
  -> versioned world definition artifact
     -> PNG layers + metadata + world content signature
     -> bake proof: stage timings + backend + deterministic content/export signatures

World Startup Coordinator
  -> resolves world and save
  -> loads world definition
  -> loads resources and prepares compute pipelines
  -> asks Terrain Artifact Store for spawn-zone artifacts
  -> materializes critical terrain, collision, buildings, vegetation, and entities
  -> releases player

Terrain Chunk Request
  -> Terrain Artifact Store lookup
     -> hit: restore data and finalize
     -> miss: compute density -> native mesh data -> store artifact -> finalize

Terrain Edit
  -> mark touched chunks and overlap neighbors dirty
  -> invalidate only affected terrain artifacts
  -> rebuild affected terrain
  -> emit chunk modification events
  -> refresh only dependent vegetation/building/runtime regions
```

## Artifact Layers

### 1. World Definition Artifact

This already exists and should remain authoritative:

- heightmap
- biomes
- roads
- water
- building footprint map
- metadata
- baked buildings, towns, and terrain modifications
- world content signature
- world-bake proof with layer validation, image signature, metadata signature,
  combined content signature, generation stage timings, hash timing, backend,
  save/export timing, and export cache signature

`WorldMapData` remains the owner of decoded world definition caching.

### 2. Terrain Chunk Artifact

This data-first reusable output is now implemented for the default native CPU
meshing path through bounded session and disk stores.

A data-first terrain artifact should contain only what is required to restore an
unchanged chunk without rerunning the full generation and meshing path:

- chunk coordinate
- artifact schema version
- artifact key/signature
- stored terrain modification version or modification hash
- deferred terrain mesh arrays
- terrain collision faces
- terrain height map
- deferred water mesh arrays and collision faces when present
- generated-water flags
- source and unique vertex counts
- optional density and material bytes needed to restore editable GPU buffers
- byte size and last-used metadata for eviction

The existing native meshing path already produces deferred mesh arrays, faces, and
height maps before main-thread materialization. That is the correct insertion
point for artifact storage.

The artifact should not contain:

- scene nodes
- `ArrayMesh` or `Shape3D` resources in the disk format
- `RID` values
- per-frame state
- references to active managers

### 3. Hot Session Resource Cache

A smaller optional session-only cache may keep materialized `ArrayMesh` or
`Shape3D` resources if profiling proves that data artifact restoration is still
too expensive. This must be separate from the default artifact store because live
resources can consume substantial render and physics memory.

Do not implement this tier first.

## Terrain Artifact Key

The key must include every input that can change generated output:

```text
world_content_signature
artifact_schema_version
terrain_generator_version
terrain_mesher_version
chunk_coordinate
chunk_size_and_stride
terrain_and_water_settings_signature
material_schema_signature
world_map_schema_signature
stored_modification_version_or_hash
```

The world content signature already exists in the world map bake. Add explicit
terrain generator and mesher version constants so shader, GDExtension, or format
changes can invalidate old artifacts without guessing.
The generator also exposes `world_bake_proof` so production snapshots can
verify the bake backend, deterministic content signature, layer set, stage
timings, and export signature before gameplay measurements begin.

### Initial Persistence Policy

- Persist only unchanged base-world chunks to disk first.
- Keep modified chunk artifacts session-only until save/load invalidation is fully
  proven.
- A world switch invalidates the active session cache.
- A world definition rebake invalidates disk artifacts through the world content
  signature.
- A terrain edit invalidates touched chunks and overlap neighbors only.
- A material schema, density shader, chunk size, or mesher format change
  invalidates incompatible artifacts only.

## Chunk Request Lifecycle

### Cache Hit

1. `_load_chunk()` registers the chunk as requested.
2. The terrain artifact store checks the session cache, then optional disk cache.
3. The restore path recreates or uploads any required density/material GPU buffers.
4. The artifact is queued through the existing pending finalization path.
5. `_finalize_chunk_creation()` materializes meshes, shapes, nodes, materials, and
   collision under the existing frame budget.
6. Existing `chunk_generated` behavior remains intact.

### Cache Miss

1. The current compute density path runs.
2. The current native CPU marching cubes path runs.
3. Before the worker result is discarded, a data-only artifact is created.
4. The artifact is inserted into the bounded session cache.
5. Eligible base-world artifacts are queued for disk persistence outside the
   gameplay-critical frame.
6. The existing finalization path runs.

### Terrain Edit

1. The edit system identifies touched chunks and required overlap neighbors.
2. Those artifact entries are invalidated before the rebuild is queued.
3. The current modification and remesh path runs.
4. New session-only modified artifacts may be stored after the rebuild.
5. `chunk_modified` continues to notify vegetation and other dependent systems.

## Memory and Disk Budgets

The cache must be budgeted by bytes, not only by entry count.

Initial configurable budgets should include:

- session terrain artifact memory budget
- optional disk terrain artifact budget
- maximum disk write bytes per second
- maximum disk writes queued
- maximum restore commits per frame
- maximum artifact serialization time per frame

Eviction should use LRU order with dirty or currently requested entries protected
from eviction.

Telemetry must report:

- entry count
- total bytes
- hit count
- miss count
- hit ratio
- disk hit count
- restore time
- generation time avoided
- evictions
- invalidations by reason
- queued disk writes
- completed disk write bytes and rate-limit wait time

## Startup Coordinator

Use the implemented `WorldStartupCoordinator` as the single startup owner.

The coordinator owns startup state and readiness. The loading UI consumes its
signals. Terrain, prefab, building, vegetation, and entity managers expose
`get_startup_readiness_snapshot()` with a shared `{ ready, pending, completed,
total, progress, message, details }` shape, so the coordinator can poll stable
contracts instead of manager internals.

### Signal Contract

```gdscript
signal load_started(load_id: String)
signal stage_started(load_id: String, stage_id: StringName, label: String, weight: float)
signal stage_progress(load_id: String, stage_id: StringName, completed: int, total: int, details: Dictionary)
signal stage_completed(load_id: String, stage_id: StringName, duration_ms: float, details: Dictionary)
signal playable_ready(load_id: String, duration_ms: float)
signal load_completed(load_id: String, duration_ms: float)
signal load_failed(load_id: String, stage_id: StringName, message: String)
signal load_cancelled(load_id: String, reason: String)
```

### Proposed Startup Stages

Weights are initial defaults only. Recalibrate them from real cold and warm load
traces so overall progress remains representative.

| Stage | Initial weight | Completion source |
|---|---:|---|
| Resolve world and save | 3 | World path, save path, and compatibility checks complete |
| Load world definition | 8 | `WorldMapData` load/decode/cache result complete |
| Load resources and prepare pipelines | 12 | Resource manifest loaded, compute thread and pipelines ready, render prewarm started |
| Restore save state | 8 | Save data parsed and manager state restored |
| Prepare spawn terrain artifacts | 27 | Required spawn-zone artifact hits restored or misses generated |
| Materialize terrain and collision | 22 | Playable-radius terrain visual and collision readiness complete |
| Apply buildings and prefabs | 8 | Critical spawn-region building/prefab queues empty |
| Place vegetation | 7 | Critical spawn-region vegetation queues empty |
| Restore entities | 3 | Critical entity restore complete |
| Release player | 2 | Input, physics, camera, and player state released |

### Readiness Levels

Startup should distinguish:

- `playable_ready`: collision-safe terrain and critical world content around the
  spawn are ready.
- `load_completed`: all work promised by the loading policy is complete.
- `background_polish`: optional work that is allowed only under idle budgets.

The project goal is to move more work before `playable_ready`, but the policy must
remain configurable so a large preheat radius does not create an excessive
loading screen.

Recommended settings:

- `startup_playable_radius_chunks`
- `startup_preheat_radius_chunks`
- `startup_require_preheat_before_play`
- `startup_collision_radius_chunks`
- `startup_critical_content_radius_chunks`

## Loading UI Contract

Keep the loading display coordinator-driven instead of returning to
manager-specific UI polling. The fallback path may read
`get_startup_readiness_snapshot()` when the coordinator is absent, but the
coordinator remains the owner of weighted progress and failure/cancellation
state.

The default loading screen should show:

- monotonic overall percentage
- current stage label
- current stage percentage
- completed and total work counts when available
- cache state such as `restoring 42/64 terrain chunks` or `generating 3 misses`
- elapsed time
- a clear failure message if startup fails

A debug detail panel may show:

- load ID
- stage durations
- cache hits, misses, bytes, and evictions
- terrain generation queue counts
- GPU sync/readback totals
- CPU meshing totals
- pending finalization count
- slowest operation

Do not expose per-chunk log spam in the default UI.

## Structured Logging and Telemetry

Implement a bounded `WorldLoadTrace` or equivalent recorder.

### Event Schema

Each event should contain:

```text
load_id
timestamp_usec
stage_id
event_name
duration_ms
completed
total
cache_result
coord_or_region_when_relevant
details
```

### Logging Policy

- Production records stage summaries, failures, cache summary, and slow outliers.
- Debug builds may keep a bounded recent event ring buffer.
- Per-chunk events are recorded only for misses, failures, invalidations, or slow
  operations over a threshold.
- Completed traces may be written as one compact JSON artifact for test harnesses.
- Logging must not allocate or print every frame.

### Existing Hooks to Use

- Replace the no-op `_capture_terrain_telemetry()` hook.
- Replace the no-op `_capture_load_telemetry()` hook.
- Keep existing detailed terrain snapshots for test harnesses.
- Use the implemented `WorldPerformanceMonitors` autoload for cached
  `Performance.add_custom_monitor()` values. Monitor callbacks return cached
  numeric samples so debugger queries do not walk the scene tree.
- Town-stall proof snapshots consume the same cached monitor values and expose
  `stationary_runtime_idle_verdict` plus window-level `world_runtime_*` fields
  for idle ratio, pending work, awake-process count, per-subsystem wake
  blockers, GPU sync, readback, and pending finalization.
- Warm and revisit proof snapshots also expose
  `stationary_terrain_artifact_cache_verdict` for ending artifact hit ratio,
  cache entries, memory/disk byte-budget ratios, eviction deltas, and disk-hit
  delta over the stationary window.
- Startup proof snapshots expose `startup_readiness_verdict` for loading-screen
  and coordinator availability, completion, active/failure/cancellation state,
  playable-ready state, completed/missing/incomplete stage counts, startup
  elapsed time, slowest stage duration, trace event count, current stage
  label/progress/counts, and compact stage detail text for stall diagnosis.
- Startup analyzer gates and town-stall runner proof gates append compact
  active-stage context to startup-readiness failures, so failed production proof
  names the current stage, stage-local progress, work counts, and blocking
  detail instead of requiring raw snapshot inspection.
- Terrain startup readiness details expose artifact restore queues, generation
  miss queues, CPU meshing queues, pending finalization type counts, visual
  batch worker queues, spawn-zone preheat, and async disk artifact write backlog
  so loading-stage details can distinguish restore work from cache misses.
- They also expose session and disk artifact cache hit/miss/store/restore
  counters plus byte-budget state, so warm startup traces can show whether the
  spawn radius is restoring cached terrain or generating misses.
- World-bake proof snapshots expose `world_bake_proof` for generation stage
  timings, height/biome backend, baked layer count and validity, stable image
  and metadata signatures, combined content signature, hash overhead,
  save/export timing, and export cache signature.
- `addons/tests/analyze_performance_snapshots.py` summarizes those verdicts and
  can enforce latest production startup-readiness, world-bake, runtime-idle,
  and terrain-artifact-cache gates from snapshot files.
- `addons/tests/run_town_stall_test.py` also prints those proof summaries and
  can enforce the same snapshot verdicts in-process through opt-in environment
  gates for production proof runs.
- `addons/tests/run_town_stall_raw_baseline.py` can pass those gates to repeated
  raw GPU baseline runs and stores the active proof-gate environment plus
  aggregated proof values in its output JSON.
- `addons/tests/analyze_performance_snapshots.py` preserves those raw-baseline
  proof verdicts and can gate the latest repeated baseline on startup readiness,
  world-bake proof, runtime idle, artifact hit ratio, cache budget pressure,
  and eviction churn.
- `addons/tests/run_world_performance_priority_proof.py` is the consolidated
  executable proof entry point. By default it runs the fast contract suite and
  existing-snapshot analyzer smoke; with `--run-production` it launches the raw
  town baseline with the same startup, world-bake, runtime-idle, and
  terrain-cache gates enabled and writes a JSON report under `.agent`.
- The same fast suite includes foundational startup/runtime contracts for
  session terrain artifact cache eviction/invalidation, disk artifact
  stale/corrupt fallback, startup preheat readiness policy, terrain process
  sleep/wake, signed runtime setting invalidation, vegetation placement cache
  reuse, entity pool reuse, work-aware entity maintenance cadence, and
  player/building/vegetation/entity viewer-position wake signals.
- It also includes focused native/helper contracts for terrain height-map
  sampling, world-map road/water mask sampling, terrain mask sample telemetry,
  building grouped mesh merge, vegetation cluster render payloads, vegetation
  native record append, vegetation noise sampling, pending chunk scheduling,
  removed-entry filtering, and generation timing telemetry.
- It validates planned proof steps before execution, so fast Godot commands must
  remain focused `addons/tests/*_test.gd` contracts or editor parse checks; bot
  and gameplay harness scripts are rejected from the fast suite.
- It writes a `completion_audit` block that separates raw production case
  coverage from contract-only coverage and keeps the roadmap incomplete until
  accepted heavy production proof, threshold tuning, GPU sync/readback A/B
  evidence, and rollout/test-hook cleanup are complete.
- `addons/tests/audit_world_performance_priority_readiness.py` is the
  non-game readiness checkpoint. It validates the `priority_full` production
  plan without launching gameplay, records current proof-report state, and
  writes the source-side rollout/test-hook cleanup queue that must be resolved
  after accepted production captures. Each cleanup candidate carries an explicit
  post-evidence action, separating removal/review hooks from tuning overrides
  that should be promoted into defaults or documented project settings.
- The wrapper also expands the default heavy `priority_full` production suite to
  runtime default, unchanged-revisit, render-distance 5/10/15, and
  memory-pressure raw baseline cases, then records covered and still-missing
  roadmap scenarios in dry-run and production JSON reports.
- The same plan counts the bounded world-map preview builder contract as
  low-resolution preview coverage when Godot contract checks are included.
- The plan counts warm startup as contract-covered when the terrain warm-startup
  preheat contract is included; that contract verifies a disk-seeded startup
  preheat queues spawn terrain as artifact restores with no generation misses.
- The plan also counts terrain world-definition change coverage when the Godot
  contract is included; that contract verifies world-switch cache isolation by
  clearing stale terrain artifacts, pending disk writes, and queued generation
  while routing save-load world changes through the terrain setter.
- The plan counts dirty edit revisit as contract-covered when the terrain
  generation telemetry contract is included; that contract verifies completed
  terrain edits refresh their session artifact and revisit through artifact
  restore instead of first-revisit generation.
- The plan counts modified-terrain save/reload as contract-covered when the
  SaveManager terrain modifications contract is included; that contract verifies
  terrain load clears live chunks before restoring saved edit payloads.
- The town-stall harness can apply terrain artifact memory/disk budget overrides
  to `TerrainManager`, allowing memory-pressure proof runs to exercise bounded
  artifact cache behavior without changing project defaults.

Implemented custom monitors include:

```text
WorldStartup/OverallProgress
WorldStartup/Active
WorldStartup/Failed
WorldStartup/Cancelled
WorldStartup/PlayableReady
TerrainArtifactCache/Entries
TerrainArtifactCache/Bytes
TerrainArtifactCache/ByteBudgetRatio
TerrainArtifactCache/HitRatio
TerrainArtifactCache/Evictions
TerrainArtifactDiskCache/Bytes
TerrainArtifactDiskCache/ByteBudgetRatio
TerrainArtifactCache/DiskHits
TerrainArtifactDiskCache/Evictions
TerrainArtifactDiskWriteQueue/PendingBytes
TerrainArtifactDiskWriteQueue/PendingEntries
TerrainArtifactDiskWriteQueue/CompletedBytes
TerrainArtifactDiskWriteQueue/RateLimitWaitMs
TerrainGeneration/GpuSyncMs
TerrainGeneration/ReadbackMs
TerrainFinalization/Pending
WorldRuntime/TerrainProcessAwake
WorldRuntime/BuildingProcessAwake
WorldRuntime/PrefabProcessAwake
WorldRuntime/VegetationProcessAwake
WorldRuntime/EntityMaintenanceAwake
WorldRuntime/AwakeProcessCount
WorldRuntime/Idle
WorldRuntime/PendingWork
```

## World Map Generator Optimization

The generator and runtime terrain pipeline are different optimization problems.
Do not combine them into one large rewrite.

### Immediate Generator Changes

1. Keep the implemented low-resolution preview tier bounded and progressive.
2. Generate the full 2048 x 2048 authoritative bake only on Save or Play.
3. Keep preview colorization at preview resolution instead of requiring a
   full-resolution main-thread color pass.
4. Keep the current deterministic metadata and content signature contract.
5. Record preview latency and full bake stage durations separately.

### Backend Responsibilities

Good GPU compute candidates:

- base height layer
- biome classification
- uniform masks
- dense per-pixel transforms
- optional road or water rasterization after CPU layout is known

Good native CPU/GDExtension candidates:

- town placement
- road graph construction
- building selection and placement
- path logic
- metadata assembly
- artifact serialization and hashing if GDScript becomes measurable

### Backend Selection

Run a focused spike for the full-resolution base layers:

- current GDScript reference
- native C++ implementation
- compute shader implementation

Select the production backend based on:

- total wall time including GPU readback
- deterministic output
- export and headless compatibility
- implementation complexity
- ability to share formulas with runtime terrain
- failure behavior on unsupported hardware

Compute shaders are valuable here, but "move everything to GPU" is not the
correct design. Branch-heavy settlement logic belongs on CPU.

## GPU Synchronization and Readback Follow-up

The current runtime path uses `rd.sync()` and `buffer_get_data()` in several
generation and modification paths. Godot 4.6 documents that `buffer_get_data()`
blocks GPU work and provides `buffer_get_data_async()` as a more performant
alternative.

This is a measured follow-up, not the first milestone.

After artifact reuse is active:

1. Measure aggregate and maximum sync/readback cost for true cache misses.
2. Prototype asynchronous density/material readback or a small ring of in-flight
   buffers.
3. Keep ordering, buffer lifetime, cancellation, and world reset behavior explicit.
4. Compare frame time, total chunk latency, memory, and failure complexity.
5. Keep the synchronous path if asynchronous readback does not improve the real
   gameplay result.

Godot also warns that large asynchronous downloads can still be expensive because
hardware bandwidth remains finite.

## Event-Driven Gameplay

Terrain still needs a budgeted processing loop while work queues are non-empty.
The goal is to disable or minimize that loop when there is no work.

Extend the implemented player `viewer_position_changed` source into a small
viewer-region activity contract when additional region-level signals are
measurably useful.

It should emit events such as:

```gdscript
signal viewer_chunk_changed(old_chunk: Vector3i, new_chunk: Vector3i)
signal viewer_motion_state_changed(is_moving: bool)
signal viewer_orientation_bucket_changed()
```

Terrain, buildings, vegetation, and entities can use those events to wake only
the work they own.

Terrain should wake for:

- viewer chunk change
- terrain edit
- save/load or world switch
- render distance or collision distance change through the implemented terrain
  runtime setting setters
- world-definition changes through the implemented terrain setter, including
  world-map GPU buffer reload and dependent cache notification
- pending generation, restore, finalization, collision, or batch queues
- spawn-zone readiness work

Terrain may sleep when:

- the viewer is in the same relevant region
- no dirty chunks exist
- no generation or restore tasks exist
- no pending finalization or collision work exists
- no visual batch or shadow update is dirty
- no startup or save/load gate is active

Use the existing building, prefab, and vegetation `set_process(false)` wake/sleep
patterns as the local implementation model.

## Roadmap

| Stage | Status | Work | Exit criteria |
|---|---|---|---|
| 0. Baseline and trace contract | complete | Add cold, warm, revisit, and edit scenarios. Re-enable structured startup and terrain trace hooks. | We can explain where startup time and revisit work go without manual log reading. |
| 1. Session terrain artifact cache | in progress | Add a bounded data-first cache at the generation-to-finalization boundary. Restore unchanged chunks through the existing finalization path. | An unchanged revisited chunk does not run density generation or native marching cubes. |
| 2. Disk artifacts and spawn preheat | in progress | Persist eligible base-world artifacts, restore them on warm load, and preheat a configurable spawn radius before player release. | Warm startup restores most spawn terrain from artifacts and generates only misses. |
| 3. Startup coordinator and loading UI | in progress | Add weighted stages, readiness levels, manager progress contracts, failure reporting, and a coordinator-driven loading screen. | Progress is monotonic, stage-correct, and tied to real work. |
| 4. Generator preview and bake optimization | in progress | Keep the implemented bounded progressive preview and worker-safe native height/biome backend, then choose any additional native or compute backends only for measured generator hotspots. | Preview is responsive and full bake time is materially lower without changing output contracts. |
| 5. GPU sync/readback experiment | in progress | Use the implemented aggregate/max sync and readback telemetry, then A/B test asynchronous readback or in-flight buffering for remaining cache misses. | Keep only a path that improves measured gameplay frame time or load time. |
| 6. Event-driven terrain coordination | in progress | Add viewer-region events and allow terrain processing to sleep when all queues are empty. | Stationary gameplay performs no unnecessary terrain coordination work. |
| 7. Dependent runtime reuse | in progress | Continue the implemented vegetation placement reuse, entity pooling, and existing building/prefab cache paths from `WORLD_RUNTIME_REUSE_ROADMAP.md`. | Unchanged revisits restore dependent content instead of rebuilding it. |
| 8. Proof sweeps and cleanup | in progress | Run cold/warm/revisit/edit tests, memory sweeps, render-distance sweeps, and remove temporary rollout hooks. | One stable, measured, bounded path remains. |

## Measurement Scenarios

Every major stage must compare these scenarios:

1. Cold world bake.
2. Low-resolution preview update.
3. Cold game startup with no terrain artifacts.
4. Warm game startup with disk artifacts.
5. First exploration into uncached terrain.
6. Leave an area and revisit unchanged terrain.
7. Edit one terrain chunk and revisit it.
8. Save, reload, and verify modified terrain correctness.
9. Switch worlds and verify no cross-world cache reuse.
10. Stationary gameplay with no pending work.

## Required Metrics

- preview latency
- full world bake total and per-stage duration
- world definition cache hit and load/decode duration
- startup total duration
- playable-ready duration
- stage durations
- startup proof completed stage count, missing/incomplete stage count, slowest
  stage duration, loading active/failure/cancellation flags, and trace event
  count
- terrain artifact memory and disk hit ratio
- terrain artifact bytes and evictions
- terrain artifact cache ending hit ratio, byte-budget ratios, eviction deltas,
  and disk-hit delta in proof windows
- terrain chunks generated
- terrain chunks restored
- GPU generation sync aggregate and maximum
- GPU readback aggregate and maximum
- native CPU mesh build aggregate and maximum
- pending finalization aggregate and maximum
- stationary `WorldRuntime/Idle` sample ratio, maximum
  `WorldRuntime/PendingWork`, and maximum `WorldRuntime/AwakeProcessCount`
- main-thread finalization budget usage
- frames over 16.67, 25, 40, and 50 ms
- stationary FPS and power
- cache memory and disk footprint

## Initial Success Targets

These are starting targets and should be recalibrated after Stage 0 traces:

- Low-resolution preview responds in under 250 ms on the development machine.
- An unchanged resident revisit restores with a terrain artifact hit ratio above
  95 percent.
- An unchanged resident revisit produces zero new terrain generation events.
- Warm startup restores most playable-radius base terrain from disk artifacts.
- No gameplay frame exceeds 40 ms because of terrain generation or restore work.
- Runtime terrain finalization remains within a 2 ms per-frame budget.
- Loading progress is monotonic and stage-correct.
- `startup_readiness_verdict` is complete before gameplay measurement begins,
  with no active loading, failure, cancellation, missing stage, or incomplete
  stage state.
- Production tracing adds less than 0.1 ms per frame and emits no per-chunk spam.
- Session cache memory and disk cache size remain within configured budgets.
- The locked town FPS, frame-time, and power baseline does not regress.

## Validation Matrix

| Change | Required validation |
|---|---|
| Artifact key or schema | Key determinism test, version invalidation test, world switch test |
| Session cache | Revisit test, eviction test, dirty invalidation test, memory budget test |
| Disk cache | Cold/warm comparison, corrupted artifact fallback, stale version fallback |
| Spawn preheat | Playable readiness test, collision-safe spawn test, loading progress test |
| Loading coordinator | Success, failure, cancel/world switch, save load, no-manager fallback, startup readiness analyzer and runner gates |
| Generator backend | Output comparison, `world_bake_proof` determinism, bake timing, backend gate, export signature smoke test |
| Async readback | Cancellation, world reset, buffer lifetime, frame-time A/B comparison |
| Event-driven processing | Stationary idle work audit using `stationary_runtime_idle_verdict` plus analyzer and runner gates, movement wake test, edit wake test, setting-change wake test, world-definition switch test |
| Proof sweeps | Fast priority proof suite, heavy raw production proof with gates, cold/warm/revisit/edit/memory/render-distance reports |

## Risks

- Caching too much live mesh or collision state can trade CPU time for excessive
  memory and render pressure.
- Disk artifacts can become stale unless every output-changing input is versioned.
- Modified terrain persistence is more complex than base-world persistence.
- Async GPU readback can increase latency and buffer lifetime complexity.
- Compute shader support is renderer and hardware dependent.
- Resource loading from multiple threads can create shared-resource hazards.
- A loading screen can become longer if the preheat radius is too aggressive.
- A sleeping terrain coordinator needs a reliable external wake source.

## Non-Goals

- Do not keep every chunk active or rendered.
- Do not persist rendering or physics `RID` values.
- Do not replace the finished `WorldMapData` cache.
- Do not rebuild the entire world after a local terrain edit.
- Do not move settlement graph logic into a compute shader.
- Do not add broad unrelated refactors to the already large chunk manager.
- Do not remove the synchronous GPU path until an alternative is proven.

## Recommended First Implementation Slice

Keep the first code change narrow and measurable:

1. Add a `TerrainArtifactStore` module with a byte-budgeted session LRU.
2. Define a versioned data-only terrain artifact schema.
3. Insert cache lookup before `_load_chunk()` queues generation.
4. Insert cache storage after native worker mesh data is ready and before it is
   discarded.
5. Restore hits through the existing pending finalization path.
6. Invalidate touched chunks on terrain modification and clear the active store on
   world switch.
7. Add telemetry counters for hit, miss, restore, invalidation, bytes, and eviction.
8. Add a repeatable leave-and-revisit test to prove generation event IDs do not
   increase for unchanged cached chunks.

Do not add disk persistence, async readback, or generator compute work in the same
first slice. Those changes have different failure modes and should be measured
independently.

## Primary Source Notes

The following Godot 4.6 documentation informs this roadmap:

- Compute shaders require a RenderingDevice-based renderer such as Forward+ or
  Mobile:
  https://docs.godotengine.org/en/4.6/tutorials/shaders/compute_shaders.html
- Local `RenderingDevice` instances can run compute work on separate threads, and
  `sync()` has a CPU-GPU synchronization cost:
  https://docs.godotengine.org/en/4.6/classes/class_renderingdevice.html
- `buffer_get_data()` blocks GPU work, while `buffer_get_data_async()` is an
  alternative with its own latency and bandwidth caveats:
  https://docs.godotengine.org/en/4.6/classes/class_renderingdevice.html
- The active scene tree is not thread-safe, while data can be prepared outside the
  tree and added on the main thread:
  https://docs.godotengine.org/en/4.6/tutorials/performance/thread_safe_apis.html
- `ResourceLoader.load_threaded_request()` and progress status can support visible
  startup resource loading:
  https://docs.godotengine.org/en/4.6/classes/class_resourceloader.html
- `Performance.add_custom_monitor()` can expose project-specific live metrics:
  https://docs.godotengine.org/en/4.6/classes/class_performance.html
- `WorkerThreadPool` is available for expensive parallel CPU tasks, but small work
  can become slower when distributed:
  https://docs.godotengine.org/en/4.6/classes/class_workerthreadpool.html

The recommendation to test asynchronous readback is an inference from the
documentation and the current code. It is not yet a measured project result.
