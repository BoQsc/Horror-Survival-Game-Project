# World Runtime Reuse Roadmap

This is the follow-up roadmap to `WORLD_MAP_CACHING_ROADMAP.md`.

It covers the next problem we actually need to solve: once the baked world map is loaded, keep the expensive runtime-generated content resident and reuse it instead of rebuilding it every time the player revisits the same area.

## Why This Roadmap Exists

The world-map cache is already real and active. The next bottleneck is the runtime work that still scales hard with render distance.

Recent stress sweeps showed:

| Render distance | Avg total ms | Avg draw calls | Avg objects | Dominant pressure |
|---|---:|---:|---:|---|
| 5 | 12.95 | 1,056 | 1,872 | GPU/Render |
| 10 | 18.11 | 2,693 | 3,805 | GPU/Render |
| 15 | 57.98 | 6,770 | 7,537 | GPU/Render |

The pressure ranking at higher distances was dominated by:

- `TerrainManager`
- `VegetationManager`
- `EntityManager`
- `BuildingManager`

That means the next work is not more baked-map loading. The next work is runtime reuse.

## Terms

- Runtime-generated content: anything created after the baked world map is loaded.
- Runtime reuse: keeping generated results in memory and restoring them instead of regenerating them.
- Cache entry: one stored runtime result for one chunk, region, or settlement.
- Dirty invalidation: marking only the touched area stale so only that area rebuilds.
- Pooling: reusing instances or resources instead of allocating new ones every time.

## What This Roadmap Does Not Change

- It does not reopen `WORLD_MAP_CACHING_ROADMAP.md`.
- It does not change the baked world-map file format.
- It does not replace the current generator/save/load flow.
- It does not require a C++ or GPU rewrite unless a measured hotspot still remains after reuse is in place.

## Explicit Runtime Contract

- Revisited unchanged terrain should restore from cached runtime data instead of rebuilding from scratch.
- Only dirty chunks or dirty regions should regenerate.
- Buildings and building blocks should be treated as reusable runtime output when they are static or effectively static.
- Vegetation should be cached or pooled per chunk or region so unchanged areas do not replant everything.
- Entity spawn pressure should be reduced by pooling or persistent chunk-aware spawn state where it is safe to do so.
- Terrain mesh and collision generation should be reduced to the smallest dirty region that actually changed.
- Runtime reuse must not break save/load correctness.
- If a cache is not safe to reuse, only that piece should rebuild, not the whole world.

## Scope

In scope:

- terrain chunk mesh reuse
- terrain collision reuse
- vegetation placement reuse
- vegetation instance pooling
- building prefab reuse
- building block reuse
- building mesh and collision reuse
- building visual batch reuse
- entity spawn pooling or persistent spawn state where safe
- cache invalidation and persistence rules for those systems
- telemetry for comparing cached and uncached paths

Out of scope:

- reopening the finished world-map roadmap
- changing baked world data schema
- unrelated signal cleanup
- unrelated debug helper scripts
- broad shader or native rewrites unless profiling says they are necessary

## Roadmap

| Stage | Status | What we will do | Exit criteria |
|---|---|---|---|
| 0. Baseline | done | Keep the current render-distance proof, the `WorldMapData` cache baseline, and the chunk-cleanup race fix as the known starting point. | We can reproduce the current numbers and compare later runs against them. |
| 1. Terrain reuse | in progress | Continue the implemented bounded terrain artifact caches so unchanged terrain can be restored instead of rebuilt. | A revisited terrain chunk comes back from cache without a full rebuild. |
| 2. Vegetation reuse | in progress | Continue the implemented bounded vegetation placement cache, existing collider pools, and dirty terrain invalidation. | Unchanged vegetation restores from cache and dirty terrain only refreshes its own vegetation. |
| 3. Entity reuse | in progress | Continue the implemented bounded scene-keyed entity pool and add persistent spawn records only where measurements justify them. | Entity pressure drops on revisits and only dirty spawn regions regenerate. |
| 4. Building and block reuse | in progress | Continue existing persistent building chunk data, prefab rotated-block cache, baked payload cache, and visual payload cache. Keep interactive state separate from static build output. | Buildings and blocks in unchanged areas return from cache instead of being rebuilt. |
| 5. Cache rules | in progress | Complete and prove invalidation rules for terrain edits, building edits, world switches, save/load, memory pressure, and settings changes. | Cache invalidation is predictable and documented for every subsystem. |
| 6. Proof sweeps | pending | Repeat the render-distance sweep with cached and uncached paths, starting at 5, 10, and 15, and extend only if needed. Measure terrain, vegetation, entity, and building costs separately. | We can point to the exact subsystem that improves. |
| 7. Hot-path follow-up | pending | If a specific hotspot still dominates after reuse, move only that measured hot path to C++/GDExtension or another lower-level implementation. | Native work is justified by measured need, not by guesswork. |
| 8. Cleanup | pending | Remove temporary hooks and test-only toggles that were only needed during rollout. | One stable runtime-reuse path remains. |

## Current Implementation Evidence

- Terrain session artifacts restore unchanged revisits through the existing
  finalization path, and eligible base-world artifacts can restore from disk.
- Successful edited-terrain rebuilds refresh their session artifact so later
  unchanged revisits can reuse the new result.
- Vegetation placement artifacts are bounded by chunk and instance budgets,
  signed by relevant generation settings, and invalidated by dirty terrain.
- Entity pooling is bounded, keyed by packed-scene resource path, and used for
  eligible non-permanent despawns.
- Entity maintenance selects timer and physics-process rates only from work
  categories that are currently present.
- Entity viewer-dependent maintenance consumes player movement signals and keeps
  a slower fallback poll for vehicles or custom viewers without compatible
  signals.
- Entity startup readiness now reports collision-relevant pending spawn work
  separately from distant procedural spawn backlog, so background spawn planning
  remains event-driven runtime work instead of a startup blocker.
- Background-only entity spawn backlog no longer keeps the maintenance timer or
  physics process awake when a viewer movement signal is connected; moving into
  the relevant area wakes the deferred spawn queue.
- Building chunk data remains resident across visual unloads, while existing
  prefab, baked building payload, and visual payload caches avoid substantial
  repeated static work.
- Terrain, building, vegetation, and entity viewer refresh paths consume
  thresholded explicit player movement signals and retain slower fallback
  polling for alternate viewers.
- Terrain render-distance, collision-distance, terrain-height, water-level,
  noise-frequency, and procedural-road runtime setters wake sleeping terrain
  coordination immediately, expose setting-change telemetry, and invalidate
  signed artifact cache state where generation output can change.
- Terrain world-definition changes flow through a public setter that clears stale
  terrain artifacts and queued generation, reloads world-map GPU buffers, and
  notifies building, prefab, and vegetation caches during save-load world
  switches.
- Signed terrain setting changes and world-definition switches also clear
  pending async disk artifact writes, so artifacts queued under an old signature
  cannot be written after the runtime definition changes.
- `WorldPerformanceMonitors` exposes cached live custom monitors for runtime
  process awake state, aggregate pending work, awake-process count, and a
  runtime idle verdict, so idle/revisit proof can inspect these values without
  per-query scene-tree scans.
- The town-stall harness records those monitor values in proof snapshots,
  including `stationary_runtime_idle_verdict` and window-level idle ratio,
  pending-work, awake-process, and subsystem-blocker fields.
- It also records `stationary_terrain_artifact_cache_verdict` so warm/revisit
  proof can compare artifact hit ratio, cache entries, byte-budget ratios,
  eviction deltas, and disk-hit delta without manual telemetry parsing.
- The same snapshots record `startup_readiness_verdict` from loading-screen and
  coordinator telemetry, so proof runs can assert gameplay measurement starts
  only after startup readiness completes.
- The snapshot analyzer summarizes those verdicts and can fail latest production
  captures when startup readiness is incomplete, stationary runtime work remains
  awake, terrain artifact reuse is not visible, budget pressure is too high, or
  eviction churn exceeds the proof threshold.
- The town-stall runner prints the same proof summaries and can enforce them
  during opt-in production proof runs, so failed idle/reuse proof no longer
  depends on manual snapshot inspection.
- The raw town-stall baseline wrapper can pass those proof gates to child runs
  and aggregate proof verdicts per case, so repeated production/reuse sweeps can
  fail on incomplete startup readiness, runtime work, cache budget pressure, or
  eviction churn automatically.
- The snapshot analyzer preserves and gates the same raw-baseline proof verdicts
  from repeated run JSON, so proof review can use one analyzer report.
- World-map bake proof now travels through the same snapshot, runner, analyzer,
  and raw-baseline flow, so runtime comparisons can also prove which baked world
  content signature, backend, export signature, and bake timing they used.
- `addons/tests/run_world_performance_priority_proof.py` provides one executable
  entry point for the fast reuse/startup/bake proof contracts and the optional
  heavy raw production proof run with those gates enabled.
- The same fast suite now includes the foundational reuse contracts for session
  artifact cache eviction/invalidation, disk artifact stale/corrupt fallback,
  startup preheat readiness policy, terrain process sleep/wake, signed runtime
  setting invalidation, vegetation placement cache reuse, entity pool reuse,
  work-aware entity maintenance cadence, and player/building/vegetation/entity
  viewer-position wake signals.
- It also includes focused native/helper contracts for building grouped mesh
  merge, vegetation cluster render payloads, vegetation native record append,
  vegetation noise sampling, pending chunk scheduling, removed-entry filtering,
  and generation timing telemetry, so native reuse helpers stay covered without
  requiring a gameplay run.
- The proof wrapper validates its planned steps before execution, rejecting
  bot/gameplay harness scripts and raw town launchers from the fast suite while
  still allowing explicit heavy production proof steps.
- Proof reports include `completion_audit`, which separates raw-case coverage
  from contract-only coverage and keeps the roadmap incomplete until accepted
  heavy production proof, threshold tuning, GPU sync/readback A/B evidence, and
  rollout/test-hook cleanup are resolved.
- `addons/tests/audit_world_performance_priority_readiness.py` records the
  non-game production-readiness state and source-side cleanup candidates, so
  rollout/test-hook cleanup now has a concrete post-evidence queue instead of
  an informal note. The queue now separates removal/review hooks from tuning
  overrides that should become stable defaults or documented project settings
  once accepted captures identify the winning values.
- Its default heavy `priority_full` production suite now expands to runtime
  default, unchanged-revisit, render-distance 5/10/15, and memory-pressure raw
  baseline cases, and its JSON output records which roadmap scenarios are
  covered versus still missing or externally prepared.
- Low-resolution preview is counted as contract-covered by the same proof plan
  when the bounded preview-builder Godot contract is included.
- Warm startup is counted as contract-covered when the terrain warm-startup
  preheat Godot contract is included; it verifies a disk-seeded startup preheat
  queues spawn terrain as artifact restores with no generation misses.
- World-switch cache isolation is counted as contract-covered when the terrain
  world-definition change Godot contract is included; it verifies stale terrain
  artifacts, pending disk writes, and queued generation are cleared across world
  changes.
- Dirty edit revisit is counted as contract-covered when the terrain generation
  telemetry Godot contract is included; it verifies completed edits refresh the
  session artifact and that the edited chunk revisits through artifact restore.
- Modified-terrain save/reload is counted as contract-covered when the
  SaveManager terrain modifications Godot contract is included; it verifies
  terrain load clears live chunks before restoring saved edit payloads.
- The town-stall harness can apply terrain artifact memory/disk budget overrides
  to `TerrainManager`, so cache memory-pressure proof has an explicit case
  instead of relying on ad hoc project setting edits.
- Terrain, prefab, building, vegetation, and entity managers expose stable
  startup readiness snapshots, so startup and fallback loading UI can report
  real pending work without polling manager-private arrays.
- The coordinator and loading-screen snapshots now expose current stage label,
  stage-local progress, completed/total counts, details, and compact
  pending/blocking summaries so production proof can explain startup stalls
  without unbounded per-manager logging.
- Startup readiness verdicts and analyzer summaries preserve those current-stage
  fields, so a failed production run carries the active loading blocker into the
  report instead of requiring manual raw snapshot inspection.
- Startup analyzer gates and town-stall runner proof gates append the same
  active-stage context to startup-readiness failures, so proof output names the
  current stage, progress, work counts, and blocking detail directly.
- Terrain startup readiness details now separate artifact restore work from
  generation misses, CPU mesh queues, finalization nodes, visual batch worker
  tasks, preheat zones, and disk write backlog, so warm/revisit proof can show
  whether startup is reusing artifacts or still generating terrain.
- Those details also carry session and disk artifact cache hit/miss/store,
  restore, byte-budget, and disk-hit counters, giving loading/proof output a
  direct cache-state summary instead of requiring raw terrain telemetry lookup.

The next requirement is production runtime proof: the current dry-run plan has
no missing roadmap scenarios, but revisit, memory-pressure, render-distance,
frame-time, idle-power, cold startup, cold bake, and warm startup still need
fresh heavy captures before they count as accepted production evidence. Warm
startup, dirty edit, and save/reload now have focused contracts, but no real
gameplay capture has been accepted as production evidence. The proof JSON now
states this directly through `completion_audit.complete=false` and lists the
remaining blockers.

## Decision Rules

- If a runtime result is static after load, cache it and reuse it.
- If a runtime result changes often, pool it or make dirty updates as small as possible.
- If a cache is expensive to keep and cheap to rebuild, do not keep it.
- If a cache is expensive to rebuild and commonly revisited, keep it.
- If the measured bottleneck moves after one fix, remeasure before choosing the next subsystem.

## Validation For Each Stage

Every stage should include:

- syntax and parse checks
- a runtime smoke check
- a render-distance sweep or comparable comparison for the touched system
- a before/after note that states what got faster and what did not

## Short Version

Bake the world map once. Reuse the baked map at runtime. Then cache or pool the expensive runtime output that still makes the machine hot: terrain chunks, vegetation, entities, buildings, and building blocks. Only escalate to native code or GPU work if profiling still shows a clear hotspot after reuse is in place.
