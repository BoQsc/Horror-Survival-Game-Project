# World Performance Status

This is the single active file for world-generation, terrain artifact, marching-cubes, loading UI, render pressure, and runtime-power work.

Update rule: replace stale sections in this file. Do not append a full diary. Keep only the latest relevant evidence per lane, plus the current decisions and next target. Raw JSON/snapshot artifacts are the history.

## Target

- Real gameplay target: `60 FPS` near `16 W`, without disabling required gameplay systems.
- Generation target: map generation and terrain artifact/mesh generation happen before play with visible loading UI/progress/logging.
- Runtime target: during gameplay, marching-cubes work happens only for real terrain edits or unavoidable streaming misses.
- Terrain truth model: seed + generator settings + density edits + material edits are authoritative. Baked chunk meshes/collision are disposable cache artifacts.
- Performance direction: prefer native/GDExtension/offline generation and low-level render paths where they remove real CPU/Godot-node/render-server cost. Do not claim progress from lowering content or disabling systems.

## Current Verdict

- Checkpoint is useful but not final.
- The current system now proves prebuilt terrain mesh resources are baked and loaded from disk during gameplay startup.
- The current system does not meet the `16 W / 60 FPS` target.
- Render-distance-10 is valid but too expensive: render/scene pressure is now the main visible problem, not repeated gameplay-time marching-cubes generation.
- Ready mesh sidecars fixed correctness of "generate mesh before play, load mesh during gameplay", but they did not produce the watt/FPS target and increased bake/store cost.
- Startup/play handoff now waits for terrain/water visual batch backlog instead of declaring readiness while batch work remains hidden.
- This improves correctness and proof honesty, but it makes the render-distance-10 startup time visibly worse until the visual batch algorithm is improved.
- Manual player handoff was previously not enabled in the manual launcher; that has been corrected and needs player verification.
- The first corrected manual handoff snapshot showed control was restored too early, while runtime work was still pending. That path has been patched to wait for stream/runtime-idle stability before releasing control.

## Current Proven State

- Full town flow can complete with proof gates enabled.
- Native world generation proof exists with height/biome backend `native`.
- Terrain artifacts are baked before play in the tested flows.
- Ready terrain mesh sidecars are baked before play and restored in the gameplay load path.
- Latest runtime proof shows `0` terrain generations during initial load and town entry; terrain chunks came from artifacts.
- Runtime idle proof can pass during hold, meaning the hold is not dominated by active marching-cubes/background terrain generation.
- Runtime idle proof now counts terrain/water visual batch backlog as pending work, so the proof can no longer pass while terrain visual batching is still dirty.
- Loading UI/startup readiness can now show `Preparing terrain visual batches...` instead of an unexplained terrain wait.
- World-map binary save path is active: `5` binary layers, `0` PNG layers in the relevant proof flow.
- Focused tests prove the native minimap builder is bound and byte-equivalent to the previous GDScript minimap algorithm.
- Focused tests prove TerrainManager can sleep during runtime-power world-work suspension.
- Focused tests and behavior evidence prove BuildingManager viewer fallback polling stays inactive when signal tracking is connected.
- Adaptive BuildingManager global visual batching avoids increasing small-population batch/surface pressure.

## Latest Evidence

### Checkpoint Focused Tests

Latest focused validation passed:

- `addons/tests/world_performance_monitors_test.gd` now proves terrain/water visual batch backlog counts as runtime pending work.
- `addons/tests/town_stall_monitor_snapshot_test.gd`
- `addons/tests/terrain_startup_preheat_test.gd` now proves strict startup waits for visual batch preparation and post-handoff dirty batches do not regress startup readiness.
- `addons/tests/terrain_process_sleep_test.gd`
- `addons/tests/terrain_warm_startup_preheat_test.gd`
- `addons/tests/terrain_startup_readiness_detail_test.gd`
- `addons/tests/terrain_runtime_setting_wake_test.gd`
- `addons/tests/building_global_visual_spatial_batch_test.gd`
- `addons/tests/building_viewer_signal_test.gd`
- `addons/tests/world_map_minimap_native_test.gd`
- `addons/tests/hud_minimap_native_path_test.gd`
- `addons/tests/entity_spawn_queue_height_path_test.gd`
- `addons/tests/terrain_artifact_disk_store_test.gd`
- `addons/tests/world_terrain_artifact_baker_contract_test.gd`
- `addons/tests/world_terrain_artifact_baker_live_smoke_test.gd` now proves parallel native ready-mesh sidecar bake + fresh disk restore.
- `python -B addons/tests/run_world_performance_priority_proof_test.py`
- `git diff --check`

Validation note: focused Godot tests were run through the project proof harness and each reported a `PASS` marker.

### Latest Checkpoint Behavior Proof

Artifact:

- `.agent/gpu-telemetry/town_stall_raw_baseline_20260614_102331.json`
- `.agent/town-stall-appdata/Godot/app_userdata/Horror Survival Game Project/debug/performance/snapshot_menu_2026-06-14_07-24-54.json`

Quality:

- Valid behavior proof.
- Noisy/contaminated, not production-clean.

Metrics:

- World generation total: `1,425.163 ms`
- Terrain artifact bake: `249` artifacts in `2,721 ms`
- Startup elapsed max: `44,219.444 ms`
- Average FPS: `56.44`
- Stationary FPS: `55.29`
- Average hold power: `25.14 W`
- Stationary hold power: `25.12 W`
- Runtime idle proof: ratio `1.0`, busy samples `0`
- Terrain process state during suspension: sleeping, reason `runtime_power_world_work_suspended`
- Building viewer fallback timer: inactive
- Building global visual batches/surfaces: `6` / `11`

Interpretation:

- This proves specific idle-waste fixes.
- This does not prove the overall performance target.

### Latest Render-Distance-10 Flow

Command class:

- `python -B addons/tests/run_town_stall_raw_baseline.py --cases priority_render_distance_10 ...`

Artifacts:

- `.agent/gpu-telemetry/town_stall_raw_baseline_20260614_115906.json`
- `.agent/town-stall-appdata/Godot/app_userdata/Horror Survival Game Project/debug/performance/snapshot_menu_2026-06-14_09-01-24.json`

Configuration:

- Case: `priority_render_distance_10`
- `TOWN_STALL_RENDER_DISTANCE=10`
- `TOWN_STALL_TERRAIN_RENDER_DISTANCE=10`
- `TOWN_STALL_BUILDING_RENDER_DISTANCE=10`
- `TOWN_STALL_TERRAIN_ARTIFACT_STORE_READY_MESH_RESOURCES=1`
- Gameplay systems on: buildings, building objects, terrain visuals, vegetation, water, entities.

Quality:

- Exit code `0`
- Proof gates passed: startup readiness, world bake, runtime idle, terrain artifact cache.
- Initial/final idle contaminated by machine CPU load; not production-clean.

Metrics:

- Average FPS: `53.64`
- Average hold power: `43.78 W`
- Stationary hold power: `44.81 W`
- Moving power: `38.20 W`
- Startup elapsed max: `109,789.384 ms`
- Startup slowest stage: `11,002.084 ms`
- World bake generation: `840.971 ms`
- Terrain artifact bake: `813` ready-mesh artifacts in `11,976 ms`
- Parallel native bake: `3` workers, `813` native density payloads, `0` GDScript density payloads
- Terrain chunks loaded: `317/317`
- Terrain visual batch dirty count at hold: `0`
- Terrain visual batch nodes at hold: `90`
- Terrain visual batch primitives at hold: `367,192`
- Terrain visual visible primitives at hold: `367,192`
- Pre-hold blocker evidence: terrain/water visual batch counts drained before hold; example start `terrain_visual_batches=166`, `water_visual_batches=164`, `runtime_pending_work=332`.
- Town-entry terrain window: `119` disk hits, `117` ready resource restores
- Artifact disk hits by snapshot: `739`
- Ready mesh resource restores: `926` total
- Runtime idle proof: ratio `1.0`, busy samples `0`, max pending work `0`, max awake process count `0`

Render pressure:

- Average draw calls: `430.41`
- Average submitted primitives: `2,284,169`
- Known render primitives: `1,343,748`
- Terrain visible primitives: `367,192`
- Vegetation primitives: `976,514`
- Tree primitives: `912,140`
- Alpha-empty primitive equivalent: `547,892`
- Contributors: `high_submitted_primitives`, `high_tree_primitives`, `high_alpha_empty_primitives`

Interpretation:

- The run really used render distance `10`.
- The prebuilt terrain mesh cache path is now proven in gameplay startup and town entry.
- Startup and pre-hold now wait for visual batch backlog instead of hiding it; the UI/proof now reports those stages.
- Runtime marching-cubes generation is not the hold problem in this proof.
- The current result is still unacceptable: FPS is below target and wattage is far above target.
- Startup became too slow because terrain/water visual batch rebuild after town entry is expensive and serial enough to be user-visible.
- Terrain primitives were reduced versus the previous proof, but tree/alpha vegetation still dominates known render primitives.

### Manual Handoff State

Issue found:

- The render-distance-10 raw baseline was unattended and printed `Manual handoff: OFF`.
- `run_manual_town_play_no_snapshots.cmd` also did not set `TOWN_STALL_MANUAL_HANDOFF=1`, so it could enter the automated hold path instead of giving player control.

Fix made:

- `addons/tests/run_manual_town_play_no_snapshots.cmd` now sets `TOWN_STALL_MANUAL_HANDOFF=1`.
- `addons/tests/run_manual_town_play_render_distance_10.cmd` exists for interactive render-distance-10 testing.
- `_restore_player_control()` clears the hold transform lock and explicitly captures the mouse before handing control back.
- Manual launch guards now ignore unrelated Codex helper Python processes and only block real Godot/town-stall test runs.

Current verification:

- First corrected manual handoff snapshot: `.agent/town-stall-appdata/Godot/app_userdata/Horror Survival Game Project/debug/performance/snapshot_menu_2026-06-14_07-46-39.json`.
- That snapshot proves manual handoff happened (`manual_control_restored`, `manual_handoff`), but it was released while the world was still not idle: `world_runtime_pending_work=255`, `terrain_finalization_pending=252`, TerrainManager awake, BuildingManager awake, average FPS `51.57`.
- Handoff logic is now patched to wait behind the same stream/prewarm/runtime-idle gate used by the benchmark before player control is restored.
- `git diff --check` passed for touched launcher/harness/log files.
- Waiting for live verification that the next manual render-distance-10 run releases control only after the playable state is actually stable.

## Current Blockers

- Startup is much too slow for a real user-facing flow: latest relevant startup max is `109.8s` at render distance `10`.
- Render-distance-10 is not acceptable: `53.64 FPS` average and `43.78 W` average hold in noisy evidence.
- Terrain artifact bake at distance `10` is still visible: `813` ready artifacts in `11.976s`.
- Terrain/water visual batch rebuild after town entry is now honest and blocking, but still algorithmically too slow.
- Render pressure is high: tree/alpha vegetation dominates known render primitives, while submitted primitive count is still very high.
- Manual handoff must be confirmed by the player after the launcher/harness correction.
- The previous manual handoff timing was bad: it released control before terrain/building runtime work was idle.
- A clean production evidence run has not been produced after the latest fixes because final idle remains machine-contaminated.

## Durable Decisions

- Terrain mesh/collision artifacts are cache, not terrain truth.
- Do not bake the whole world as one final authoritative mesh.
- Bake chunk artifacts and rebuild them from density/edit data when versions or edits require it.
- Do not lower render distance, disable vegetation/buildings/entities, or reduce content to claim the real target.
- Do not treat ArrayMesh caching alone as the strategic endpoint if Godot node/surface/render-server overhead remains the bottleneck.
- Low-level RenderingDevice/RenderingServer terrain rendering remains a candidate, but only after a design pass tied to measured render pressure.
- Long production runs should validate a concrete hypothesis; they should not be the main development loop.

## Next Target

1. Reduce terrain/water visual batch rebuild cost after town entry without lowering content or render distance.
2. Reduce tree/alpha vegetation render pressure algorithmically; it is now the largest known primitive contributor.
3. Reduce ready-sidecar bake/store cost without losing the proven runtime restore path.
4. Re-run manual render-distance-10 handoff and confirm control is released only after terrain/water visual batch backlog and runtime pending work are zero.
5. Re-run focused tests after each fix; use full production evidence only when the next hypothesis is specific.

## File Maintenance Rule

- Keep this file short.
- Replace old latest evidence instead of appending another long section.
- Keep at most one latest entry per lane: focused tests, checkpoint behavior proof, render-distance-10 proof, manual-control state.
- Store detailed history in raw artifacts and snapshots, referenced by path here.
