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
- Startup readiness now reports terrain/water visual batch backlog instead of declaring readiness while batch work remains hidden.
- Loading progress was wrong in one important case: it could show `1000/1000` while restored terrain artifacts still had pending finalization nodes. The snapshot path now caps progress below `100%` until readiness is actually true.
- Manual player handoff was previously not enabled in the manual launcher; that has been corrected.
- Manual handoff is immediate by default for player testing, but it now forcefully leaves editor/fly mode, restores PLAY mode, and keeps the harness editor process disabled.
- Render-distance-5 manual play exposed a real interaction flaw: mesh-only artifacts restore visuals, but not hot density/material source buffers, so first terrain edits can require source hydration and feel delayed/glitched.
- Runtime power suspension was also still active at manual handoff in the RD5 snapshot; terrain edit entry points now explicitly wake foreground terrain work before queuing edit or hydration tasks.
- Loading UI terminology was misleading: generic `cache`/`artifacts` text could make a fresh successful terrain bake look like cache failure. The UI now separates `terrain_artifacts`, `stored_new`, `reused_disk`, memory artifact hits/misses, disk artifact hits/misses, and restored baked artifacts.
- Manual play flow root cause: the generic Python town-stall runner defaulted render distance to `3`, and the harness put manual handoff behind an artificial `Preparing playable town` overlay plus a 300-frame runtime-idle wait. Manual play now defaults to render-distance `10`, stores editable source buffers by default, and restores player control immediately unless `TOWN_STALL_MANUAL_HANDOFF_WAIT_FOR_IDLE=1` is explicitly requested.
- Latest render-side fix: terrain batch visibility was culling against a shifted center-derived AABB instead of the batch origin/span. This can hide visible batched chunks and look like unload/holes. Batch culling now uses real batch bounds.
- Latest vegetation fix: world-map tree batches now use the mesh LOD data already generated for trees through `world_map_tree_render_lod_bias=0.5`, with telemetry reporting effective per-kind LOD bias. This does not change render distance or tree density.
- Latest terrain-artifact runtime fix: above-ground world-map spawn/preheat requests now use only the baked/runtime `Y=0` layer by default. The previous spawn-zone contract requested `Y-1/Y/Y+1`; at radius `2` that exactly explains the `50` unwanted post-bake generation misses (`5*5*2`).
- Latest launcher fix: the Python town-stall runner no longer forces `TOWN_STALL_MESH_LOD_THRESHOLD=0` by default. Generated tree mesh LOD data now remains available to Godot unless a run explicitly overrides the viewport mesh LOD threshold.
- Latest evidence fix: town-stall snapshots now record `system_telemetry.rendering.mesh_lod_threshold`, whether it was env-overridden, engine max FPS, and viewport size. The Python proof summary prints this line, so the next full-flow run can prove whether LOD is actually available.
- Latest render-pressure fix: world-map tree render batches now default to one terrain chunk per MultiMesh batch. This is because Godot chooses one LOD level for the whole MultiMesh AABB, so larger tree clusters kept too many far trees in the same expensive LOD/cull decision as nearby trees.

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
- Loading UI text now distinguishes fresh bake stores, disk reuse, and runtime baked-artifact restores instead of exposing ambiguous `cache` wording.
- Manual player handoff no longer shows the harness-only late loading overlay or holds movement behind the stability wait by default. The wait remains available for production evidence runs through `TOWN_STALL_MANUAL_HANDOFF_WAIT_FOR_IDLE=1`.
- Startup finalization now keeps the startup pending-node commit budget active after the chunk counter reaches its target, until the startup visual gate is satisfied.
- Terrain RenderingServer batch visibility now uses the batch origin plus batch span for frustum/angle culling and near-keep checks.
- World-map dirty terrain/water visual batches are allowed to catch up during active movement instead of staying paused while the player moves.
- World-map tree render batches now use the tree-specific LOD bias and existing batches are reconfigured when the profile becomes active.
- World-map tree render batches now default to one terrain chunk per batch, tightening culling/LOD without removing trees.
- World-map above-ground spawn/preheat no longer requests unbaked vertical terrain layers; procedural/non-world terrain keeps the previous three-layer default.
- Town-stall launch defaults no longer disable viewport mesh LOD selection; explicit `TOWN_STALL_MESH_LOD_THRESHOLD` still wins.
- Full-flow snapshots now include rendering telemetry for mesh LOD threshold/override state instead of relying only on console output.

## Latest Evidence

### Checkpoint Focused Tests

Latest focused validation passed:

- `addons/tests/world_performance_monitors_test.gd` now proves terrain/water visual batch backlog counts as runtime pending work.
- `addons/tests/town_stall_monitor_snapshot_test.gd`
- `addons/tests/terrain_startup_preheat_test.gd` now proves strict startup waits for visual batch preparation, post-handoff dirty batches do not regress startup readiness, and world-map above-ground preheat requests only the baked `Y=0` layer.
- `addons/tests/terrain_render_backend_test.gd` now proves terrain batch visibility culling uses real batch bounds instead of shifted center bounds.
- `addons/tests/vegetation_opaque_material_optimization_test.gd` now proves world-map tree batches receive tree-specific LOD bias, default to one terrain chunk per tree batch, and expose telemetry for the effective profile.
- `addons/tests/town_stall_test_harness.gd` passed Godot `--check-only` after adding rendering telemetry to snapshots.
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
- `addons/tests/loading_screen_progress_test.gd`
- `addons/tests/world_map_generator_ui_progress_test.gd`
- `addons/tests/run_town_stall_launcher_defaults_test.py` now proves default render distance `10`, manual handoff auto-teleport/source-buffer defaults, and that mesh LOD threshold is not forced to `0`.
- `addons/tests/town_stall_manual_handoff_policy_test.gd`
- `python -B addons/tests/run_world_performance_priority_proof_test.py`
- `python -m py_compile addons/tests/run_town_stall_test.py addons/tests/run_town_stall_launcher_defaults_test.py`
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

### Latest Manual Render-Distance-5 Diagnosis

Artifacts:

- `.agent/town-stall-appdata/Godot/app_userdata/Horror Survival Game Project/debug/performance/snapshot_menu_2026-06-14_10-18-54.json`
- `.agent/town-stall-godot.log`
- `.agent/town-stall-system-samples.jsonl`

Configuration:

- `TOWN_STALL_RENDER_DISTANCE=5`
- `TOWN_STALL_TERRAIN_RENDER_DISTANCE=5`
- `TOWN_STALL_BUILDING_RENDER_DISTANCE=5`
- `TOWN_STALL_MANUAL_HANDOFF=1`
- `TOWN_STALL_TERRAIN_ARTIFACT_STORE_READY_MESH_RESOURCES=1`
- `TOWN_STALL_TERRAIN_ARTIFACT_STORE_SOURCE_BUFFERS` was not set for this run.

Observed:

- Manual handoff completed after `runtime_idle_stabilizing=299/300`.
- Terrain artifact bake stored `365` ready mesh artifacts.
- `store_ready_mesh_resources=true`.
- `store_source_buffers=false`.
- Terrain manager reported `terrain_artifact_mesh_only_restore_count=303`.
- Terrain manager reported `terrain_artifact_source_hydrate_request_count=1`.
- Terrain manager reported `runtime_power_world_work_suspended=true` at the handoff snapshot.
- Raw GPU samples after handoff were roughly `29-32 W`, `79-80 C`, `43-50%` utilization, P2 state.

Interpretation:

- This was not a clean player-facing flow. It was the town-stall test harness with visible loading overlays and pre-handoff control lock.
- The delayed/glitched terrain interaction is explained by mesh-only artifact restore plus first-touch density hydration.
- The runtime-power state at handoff also made terrain edit queuing fragile; edit entry points must wake foreground terrain work directly instead of relying only on input events.

Patch status:

- Manual handoff bakes now default to source-buffer artifacts unless `TOWN_STALL_TERRAIN_ARTIFACT_STORE_SOURCE_BUFFERS=0` is explicitly set.
- Manual RD5/RD10 launchers explicitly set `TOWN_STALL_TERRAIN_ARTIFACT_STORE_SOURCE_BUFFERS=1`.
- `modify_terrain()` and `fill_column()` now wake runtime foreground terrain work before queuing terrain edit tasks.

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
- Latest player screenshot still showed the HUD label `EDITOR`, which means handoff did not force PLAY mode strongly enough.
- Loading screenshot showed `Preparing terrain 100% (1000/1000)` while `Finalizing restored terrain artifacts... (151 pending)` was still active.

Fix made:

- `addons/tests/run_manual_town_play_no_snapshots.cmd` now sets `TOWN_STALL_MANUAL_HANDOFF=1`.
- `addons/tests/run_manual_town_play_render_distance_10.cmd` exists for interactive render-distance-10 testing.
- `_restore_player_control()` clears the hold transform lock and explicitly captures the mouse before handing control back.
- Manual launch guards now ignore unrelated Codex helper Python processes and only block real Godot/town-stall test runs.
- `_restore_player_control()` now forces PLAY mode, clears fly mode, re-enables movement/camera, and keeps `ModeEditor` processing disabled.
- Terrain startup readiness now keeps progress below `100%` while any readiness blocker remains.
- Pending terrain node finalization keeps the startup commit budget after the initial chunk counter reaches target, until the startup visual gate is satisfied.

Current verification:

- Latest inspected manual snapshot: `.agent/town-stall-appdata/Godot/app_userdata/Horror Survival Game Project/debug/performance/snapshot_menu_2026-06-14_12-41-01.json`.
- Terrain artifacts were used: `terrain_generation_complete_count=0`, `terrain_generation_unique_coord_count=0`, `artifact_disk_cache_pack_load_count=1`, `loaded_pack_entry_count=813`, `artifact_disk_cache_pack_hit_count=735`, `terrain_artifact_ready_resource_restore_count=886`.
- Loaded terrain target was met: `active_chunk_count=317`, `loaded_chunk_count=317`, `render_distance=10`, `terrain_stream_under_target=false`.
- Bad visible state was not caused by missing artifact usage. It was caused by restore finalization / visual batch / handoff state still being active or exposed: snapshot had `terrain_visual_batch_dirty_count=166`, `water_visual_batch_dirty_count=166`, `latest_world_performance_monitors.world_runtime_pending_work=362`, and screenshot still showed `EDITOR`.
- Focused tests now passing for the handoff and readiness fixes: `addons/tests/town_stall_manual_handoff_policy_test.gd`, `addons/tests/terrain_startup_readiness_detail_test.gd`, `addons/tests/loading_screen_progress_test.gd`, `addons/tests/world_map_generator_ui_progress_test.gd`, `addons/tests/run_town_stall_launcher_defaults_test.py`, `python -m py_compile addons/tests/run_town_stall_test.py addons/tests/run_town_stall_launcher_defaults_test.py`, and `git diff --check`.
- Additional focused tests now passing for the render fixes: `addons/tests/terrain_render_backend_test.gd`, `addons/tests/vegetation_opaque_material_optimization_test.gd`, `addons/tests/terrain_startup_preheat_test.gd`, `addons/tests/town_stall_manual_handoff_policy_test.gd`, `addons/tests/run_town_stall_launcher_defaults_test.py`, `python -m py_compile addons/tests/run_town_stall_test.py addons/tests/run_town_stall_launcher_defaults_test.py`, and `git diff --check`.
- Direct headless run of `addons/tests/vegetation_mesh_lod_render_test.gd` did not produce live frame primitive samples in this environment, so it is not being used as production evidence. The code-level LOD profile is covered by focused behavior tests and the renderer documentation contract.

## Current Blockers

- Startup is much too slow for a real user-facing flow: latest relevant startup max is `109.8s` at render distance `10`.
- Render-distance-10 is not acceptable: `53.64 FPS` average and `43.78 W` average hold in noisy evidence.
- Terrain artifact bake at distance `10` is still visible: `813` ready artifacts in `11.976s`.
- Terrain/water visual batch rebuild after town entry is now honest and blocking, but still algorithmically too slow.
- Render pressure is high: tree/alpha vegetation dominates known render primitives, while submitted primitive count is still very high.
- Manual handoff must be confirmed by the player after the force-PLAY/fly-off and auto-teleport correction.
- Startup finalization and visual batch presentation are still too slow, even though the UI and finalization budget are now less wrong.
- A clean production evidence run has not been produced after the latest fixes. The latest short full-flow attempt did not launch because an existing Godot process was already running: `PID 5176`, started `2026-06-14 19:03:47`.

## Durable Decisions

- Terrain mesh/collision artifacts are cache, not terrain truth.
- Do not bake the whole world as one final authoritative mesh.
- Bake chunk artifacts and rebuild them from density/edit data when versions or edits require it.
- Do not lower render distance, disable vegetation/buildings/entities, or reduce content to claim the real target.
- Do not treat ArrayMesh caching alone as the strategic endpoint if Godot node/surface/render-server overhead remains the bottleneck.
- Low-level RenderingDevice/RenderingServer terrain rendering remains a candidate, but only after a design pass tied to measured render pressure.
- Long production runs should validate a concrete hypothesis; they should not be the main development loop.

## Next Target

1. Re-run the focused/manual render-distance-10 flow after the existing Godot process is closed, and inspect the snapshot for `system_telemetry.rendering.mesh_lod_threshold`, `terrain_visual_batch_dirty_count`, `last_terrain_render_visibility_batch_visible_count`, `effective_vegetation_render_cluster_size`, `effective_vegetation_tree_render_lod_bias`, tree batch bounds/instances, submitted primitives, and HUD PLAY state.
2. If terrain batch dirty counts still remain high, move terrain batch construction out of gameplay frames or persist reusable merged batch artifacts instead of only per-chunk mesh artifacts.
3. Reduce ready-sidecar bake/store cost without losing the proven runtime restore path.
4. If vegetation remains dominant, replace tree alpha geometry/material path more deeply rather than only relying on LOD bias.
5. Re-run focused tests after each fix; use full production evidence only when the next hypothesis is specific.

## File Maintenance Rule

- Keep this file short.
- Replace old latest evidence instead of appending another long section.
- Keep at most one latest entry per lane: focused tests, checkpoint behavior proof, render-distance-10 proof, manual-control state.
- Store detailed history in raw artifacts and snapshots, referenced by path here.
