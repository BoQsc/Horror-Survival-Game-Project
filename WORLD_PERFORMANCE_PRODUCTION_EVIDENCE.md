# World Performance Production Evidence

Accepted production evidence for the world startup, terrain cache, runtime idle,
and production proof gates.

## Map-Generation Terrain Artifact Bake Evidence

### June 11 Strict Town-Entry Proof

Date: June 11, 2026

Primary artifact:

- `.agent/gpu-telemetry/town_stall_raw_baseline_20260611_101404.json`

Command scope:

- `priority_warm_disk_restore`
- `TOWN_STALL_TERRAIN_ARTIFACT_BAKE_BEFORE_PLAY=1`
- `TOWN_STALL_TERRAIN_ARTIFACT_BAKE_RADIUS=1`
- `TOWN_STALL_TERRAIN_ARTIFACT_STORE_READY_MESH_RESOURCES=1`
- Required startup proof, native world-bake proof, runtime-idle proof,
  disk-hit proof, and ready-resource restore proof

Result:

| Metric | Value |
|---|---:|
| Process exit | 0 |
| Content valid | true |
| Pre-play terrain artifact bake | 54 / 54 artifacts |
| Bake elapsed | 5,696 ms |
| Runtime disk artifact hits | 18 |
| Runtime ready mesh/shape restores | 20 |
| Runtime idle ratio | 1.000 |
| Runtime busy samples | 0 |
| FPS | 59.034 |
| Hold power | 41.747 W |
| Hold WPF60 | 42.431 |
| Cache hit ratio | 0.137 |
| Cache memory budget ratio | 0.407 |
| Cache evictions | 0 |

Inspectable artifact path:

```text
.agent\town-stall-appdata\Godot\app_userdata\Horror Survival Game Project\worlds\town_stall_12345_27408\terrain_artifacts
```

The artifact directory contains `54` binary `.var` payloads and `40` binary
`.res` ready mesh/collision sidecars. This run closes the previously missing
strict proof combination: map generation bakes terrain artifacts before play,
gameplay starts from the saved world-local artifact directory, disk artifacts
are hit, and ready mesh/collision sidecars are restored.

Limitation: this is a radius-1 proof run, not full render-distance coverage.
The hold still costs about `42 W` because the measured bottleneck is now render
pressure, especially tree/alpha primitives, not marching-cubes generation in
the hold window. Full production coverage should use a terrain artifact bake
radius matching the gameplay render-distance target and then reduce submitted
tree/alpha primitives.

Date: June 7, 2026

This section records the correction for the map-generator gap. The earlier
accepted runs proved runtime terrain artifact reuse and warm disk restore, but
they did not prove that saving a newly generated map also generated and saved
marching-cubes terrain mesh artifacts before play. The new implementation adds
that pre-game bake.

Primary artifacts:

- `.agent/world-performance-priority-proof.json`
- `.agent/gpu-telemetry/town_stall_raw_baseline_20260607_133020.json`
- `C:\Users\Windows10_new\AppData\Roaming\Godot\app_userdata\Horror Survival Game Project\worlds\world_terrain_artifact_baker_live_2407062\live_smoke_status.json`
- `C:\Users\Windows10_new\AppData\Roaming\Godot\app_userdata\Horror Survival Game Project\worlds\world_terrain_artifact_baker_live_2278790\live_smoke_status.json`
- `C:\Users\Windows10_new\AppData\Roaming\Godot\app_userdata\Horror Survival Game Project\worlds\world_terrain_artifact_baker_live_2341717\live_smoke_status.json`

Top-level smoke proof result:

| Metric | Value |
|---|---:|
| Passed | true |
| Completed steps | 51 / 51 |
| Total duration | 649.449 s |
| Production suite | priority_smoke |
| Production case | runtime_default |
| Completion audit complete | false |

Live bake smoke output:

| Metric | Value |
|---|---:|
| Artifact count | 3 |
| Manifest written | true |
| Live smoke duration | 7,606 ms |
| Bake backend in headless smoke | offline native GDExtension fallback |

Inspectable artifact path:

```text
C:\Users\Windows10_new\AppData\Roaming\Godot\app_userdata\Horror Survival Game Project\worlds\world_terrain_artifact_baker_live_2407062\terrain_artifacts
```

Files written by the live smoke:

```text
terrain_artifacts\terrain_artifact_bake_manifest.json
terrain_artifacts\68b1d9df19cf2f00350d5496d0d3d623b5d7f7e9f595339725e81ea5d9ff49ed\0_-1_0.var
terrain_artifacts\68b1d9df19cf2f00350d5496d0d3d623b5d7f7e9f595339725e81ea5d9ff49ed\0_0_0.var
terrain_artifacts\68b1d9df19cf2f00350d5496d0d3d623b5d7f7e9f595339725e81ea5d9ff49ed\0_1_0.var
```

Post-edit focused verification reran the same live smoke and wrote the same
three-artifact shape under:

```text
C:\Users\Windows10_new\AppData\Roaming\Godot\app_userdata\Horror Survival Game Project\worlds\world_terrain_artifact_baker_live_2278790\terrain_artifacts
```

That rerun reported `artifact_count = 3`, `manifest_written = true`, and
`msec = 8508`.

Corrected ready-resource verification reran the live smoke again under:

```text
C:\Users\Windows10_new\AppData\Roaming\Godot\app_userdata\Horror Survival Game Project\worlds\world_terrain_artifact_baker_live_2341717\terrain_artifacts
```

That run reported `artifact_count = 3`, `manifest_written = true`, and
`msec = 9024` in the status file. The bake manifest records
`store_ready_mesh_resources = true`, `stored_artifact_count = 3`, and
`elapsed_ms = 6659.648`.

Files written by the corrected ready-resource smoke:

```text
terrain_artifacts\terrain_artifact_bake_manifest.json
terrain_artifacts\68b1d9df19cf2f00350d5496d0d3d623b5d7f7e9f595339725e81ea5d9ff49ed\0_-1_0.var
terrain_artifacts\68b1d9df19cf2f00350d5496d0d3d623b5d7f7e9f595339725e81ea5d9ff49ed\0_0_0.var
terrain_artifacts\68b1d9df19cf2f00350d5496d0d3d623b5d7f7e9f595339725e81ea5d9ff49ed\0_0_0_terrain_mesh.res
terrain_artifacts\68b1d9df19cf2f00350d5496d0d3d623b5d7f7e9f595339725e81ea5d9ff49ed\0_0_0_terrain_shape.res
terrain_artifacts\68b1d9df19cf2f00350d5496d0d3d623b5d7f7e9f595339725e81ea5d9ff49ed\0_1_0.var
```

The stored artifact uses binary `.var` payloads for density/material/editable
state plus binary `.res` sidecars for ready `ArrayMesh` and
`ConcavePolygonShape3D` resources when the bake produces a visible surface.
`ArrayMesh` is not random extra work here; it is Godot's render mesh resource.
The performance requirement is that it is produced during map-generation bake
and restored from sidecar on startup, not regenerated during visible gameplay.

The live smoke used the offline native path because the headless test emitted a
`compute_device_failed` event while creating the local rendering device. The
fallback still uses the GDExtension `MeshBuilder` marching-cubes implementation
and stores artifacts through the same `ChunkManager` artifact signature and disk
store path used by gameplay. In a runtime where the local compute device is
available, the baker first tries the normal `ChunkManager` generation path.

Production raw baseline summary from the same proof:

| Metric | Value |
|---|---:|
| Startup proof | 5 stages, pass |
| World-bake proof | native, pass |
| Max startup elapsed | 244,247.814 ms |
| Max startup stage | 33,880.370 ms |
| World-bake generation | 23,944.318 ms |
| Runtime idle ratio | 1.000 |
| Runtime busy samples | 0 |
| Terrain artifact cache hit ratio | 0.113 |
| Cache byte-budget ratio | 0.559 |
| Cache evictions | 0 |

Interpretation: the missing map-generation terrain artifact bake is now
implemented and smoke-proven, but this is not a final full-priority acceptance.
The current `completion_audit` remains false because the `priority_smoke` suite
does not cover unchanged revisit, render-distance 5/10/15, or memory-pressure
raw scenarios, and the audit still requires threshold tuning, GPU
sync/readback A/B, and cleanup of temporary rollout/test hooks.

FPS/power correction: the original target is about 16 watts at 60 FPS. The
June 7 raw telemetry showed stationary `Engine.max_fps = 15` and moving
`Engine.max_fps = 30`, so that low-power evidence is not valid as gameplay
acceptance. Runtime power now keeps the visible cap at the active 60 FPS target
unless render-loop suspension is actually allowed; idle/deep-idle requested FPS
is still logged separately for diagnostics.

## Accepted Run

Date: June 5, 2026

Primary artifacts:

- `.agent/world-performance-priority-proof-production-evidence-after-rd15-timeout.json`
- `.agent/gpu-telemetry/town_stall_raw_baseline_20260605_112350.json`
- `.agent/world-performance-priority-analysis.json`

Top-level proof result:

| Metric | Value |
|---|---:|
| Passed | true |
| Completed steps | 47 / 47 |
| Total duration | 1,697.611 s |
| Raw production duration | 1,620.071 s |
| Analysis gate duration | 0.486 s |

Raw proof gate summary:

| Metric | Value |
|---|---:|
| Proof runs | 6 |
| Startup proof runs | 6 |
| World-bake proof runs | 6 |
| World-bake backend | native |
| Max startup elapsed | 157,059.244 ms |
| Max startup stage | 18,349.373 ms |
| Max world-bake generation | 29,159.818 ms |
| Max world-bake hash | 1,612.341 ms |
| Min baked layers | 5 |
| Min runtime idle ratio | 1.000 |
| Max runtime busy samples | 0 |
| Min terrain artifact cache hit ratio | 0.096 |
| Max terrain artifact cache byte budget ratio | 0.993 |
| Max terrain artifact cache eviction delta | 0 |

Per-case raw results:

| Case | Result | Duration | Runtime idle | Busy samples | Cache hit | Cache budget | Evictions |
|---|---:|---:|---:|---:|---:|---:|---:|
| runtime_default | pass | 253.374 s | 1.000 | 0 | 0.137 | 0.403 | 0 |
| priority_revisit | pass | 321.393 s | 1.000 | 0 | 0.587 | 0.403 | 0 |
| priority_render_distance_5 | pass | 217.877 s | 1.000 | 0 | 0.173 | 0.161 | 0 |
| priority_render_distance_10 | pass | 197.618 s | 1.000 | 0 | 0.132 | 0.403 | 0 |
| priority_render_distance_15 | pass | 232.324 s | 1.000 | 0 | 0.112 | 0.741 | 0 |
| priority_memory_pressure | pass | 195.968 s | 1.000 | 0 | 0.096 | 0.993 | 0 |

## Interpretation

The accepted run proves the current production gate, not final roadmap closure.
The important evidence is that startup, native world bake, runtime idle, and
terrain artifact cache proof all pass in the heavy `priority_full` suite.
Stationary gameplay is not doing terrain/runtime work in the measured hold
windows: every raw case reports an idle ratio of `1.000` and `0` busy samples.

The cache evidence also proves reuse is visible and bounded. The memory pressure
case reaches `0.993` of its byte budget without eviction churn, and the revisit
case reports the strongest cache hit ratio at `0.587`.

Historical limitation: this first accepted heavy run predates the ready
mesh/collision sidecar path. It proves startup, session terrain reuse, native
world bake, and stationary idle, but not final mesh/collision resource restore.
That gap is closed by the later ready-resource sidecar proof below.

The accepted production hold windows also show `disk_hit_delta = 0` for every
raw case. That means the accepted proof exercised the session artifact cache and
runtime idle behavior, but it did not prove warm disk artifact restore in the
heavy production run. Existing disk artifacts from proof runs live under the
Godot user-data sandbox, for example:

```text
.agent/town-stall-appdata/Godot/app_userdata/Horror Survival Game Project/terrain_artifacts/<settings-signature-sha256>/<chunk_x>_<chunk_y>_<chunk_z>.var
```

At the time, the sandbox contained `1,026` `.var` artifact files totaling about
`701 MB`. Those files were the pre-sidecar artifact format and were not hit
during the accepted production hold windows.

## Final No-Failure Smoke

Date: June 5, 2026

Primary artifacts:

- `.agent/world-performance-priority-proof-final-smoke.json`
- `.agent/gpu-telemetry/town_stall_raw_baseline_20260605_153840.json`
- `.agent/world-performance-priority-analysis-final-smoke.json`
- `.agent/world-performance-priority-smoke-analysis-final-smoke.json`

Top-level proof result:

| Metric | Value |
|---|---:|
| Passed | true |
| Completed steps | 48 / 48 |
| Total duration | 290.335 s |
| Raw production duration | 209.524 s |
| Analysis gate duration | 0.393 s |

Raw `runtime_default` evidence:

| Metric | Value |
|---|---:|
| Raw duration | 209.314 s |
| Initial idle clean | true |
| Final idle clean | true |
| Startup completed stages | 5 |
| Startup elapsed | 98,881.239 ms |
| Max startup stage | 9,818.542 ms |
| World-bake backend | native |
| World-bake generation | 18,040.400 ms |
| Native height/biome stage | 764.746 ms |
| World-bake hash | 1,249.435 ms |
| Save total | 2,656.832 ms |
| Runtime idle ratio | 1.000 |
| Runtime busy samples | 0 |
| Terrain artifact cache hit ratio | 0.127 |
| Terrain artifact cache byte budget ratio | 0.399 |
| Terrain artifact cache evictions | 0 |
| Disk hit delta | 0 |

The final smoke includes the new fast contract
`world_map_generator_ui_progress_contract`, so the no-failure report covers the
generator UI placeholder/progress/backend telemetry path. After this capture,
runtime exploration disk writes were changed back to opt-in because this smoke
did not prove a warm disk-hit benefit.

The proof sandbox contains `1,208` `.var` files totaling about `821 MB`, under:

```text
.agent/town-stall-appdata/Godot/app_userdata/Horror Survival Game Project/terrain_artifacts/<settings-signature-sha256>/<chunk_x>_<chunk_y>_<chunk_z>.var
```

This proves the final smoke path had no failing proof steps after the UI work.
It still does not prove warm disk artifact restore in a production hold window
because `runtime_default` is a cold case and reports `disk_hit_delta = 0`. A
dedicated warm-start/disk-restore production case below closes that gap by
requiring `disk_hit_delta > 0` in the town-entry phase.

## Warm Disk-Restore Production Proof

Date: June 5, 2026

Primary artifacts:

- `.agent/world-performance-priority-proof-warm-disk-restore.json`
- `.agent/gpu-telemetry/town_stall_raw_baseline_20260605_161446.json`
- `.agent/world-performance-priority-analysis-warm-disk-restore.json`
- `.agent/world-performance-priority-smoke-analysis-warm-disk-restore.json`

Top-level proof result:

| Metric | Value |
|---|---:|
| Passed | true |
| Completed steps | 48 / 48 |
| Total duration | 485.666 s |
| Raw production duration | 399.483 s |
| Analysis gate duration | 0.435 s |
| Production evidence status | executed_passed |
| Initial idle clean | true |
| Final idle clean | true |

Raw proof gate summary:

| Metric | runtime_default | priority_warm_disk_restore |
|---|---:|---:|
| Result | pass | pass |
| Failure reasons | 0 | 0 |
| Startup completed stages | 5 | 5 |
| Startup elapsed | 96,480.287 ms | 100,119.683 ms |
| Max startup stage | 6,838.316 ms | 7,886.969 ms |
| World-bake backend | native | native |
| World-bake generation | 19,647.394 ms | 20,566.701 ms |
| Runtime idle ratio | 1.000 | 1.000 |
| Runtime busy samples | 0 | 0 |
| Stationary disk-hit delta | 0 | 0 |
| Town-entry disk-hit delta | 85 | 85 |
| Town-entry cache samples | 1,983 | 1,774 |
| Town-entry cache hit ratio | 0.137 | 0.137 |
| Cache byte budget ratio | 0.403 | 0.401 |
| Cache evictions | 0 | 0 |

The `priority_warm_disk_restore` case sets
`TOWN_STALL_TERRAIN_ARTIFACT_CACHE_PROOF_PHASE=town_entry` and the production
runner requires `--min-terrain-artifact-cache-disk-hit-delta 1`. The accepted
run therefore proves the warm startup/town-entry window loaded terrain
artifacts from disk. It also proves that stationary gameplay did not keep
loading artifacts from disk after the entry work finished: both cases report
`stationary disk-hit delta = 0`.

Snapshot paths:

```text
.agent/town-stall-appdata/Godot/app_userdata/Horror Survival Game Project/debug/performance/snapshot_menu_2026-06-05_13-17-12.json
.agent/town-stall-appdata/Godot/app_userdata/Horror Survival Game Project/debug/performance/snapshot_menu_2026-06-05_13-20-24.json
```

The artifact path remains:

```text
.agent/town-stall-appdata/Godot/app_userdata/Horror Survival Game Project/terrain_artifacts/<settings-signature-sha256>/<chunk_x>_<chunk_y>_<chunk_z>.var
```

This run predates the ready mesh/collision sidecar implementation. It proves
warm disk artifact reuse through the legacy `disk_hit_delta` gate, but the
artifact format was still a binary `.var` payload containing base terrain
buffers and deferred mesh surface arrays.

## Ready Mesh/Collision Sidecar Evidence

Date: June 5, 2026

Historical ready-resource production artifacts:

- `.agent/world-performance-priority-proof-ready-mesh-restore-accepted.json`
- `.agent/gpu-telemetry/town_stall_raw_baseline_20260605_174822.json`
- `.agent/world-performance-priority-analysis-ready-mesh-restore-accepted.json`
- `.agent/world-performance-priority-smoke-analysis-ready-mesh-restore-accepted.json`

Pre-fix top-level proof result:

| Metric | Value |
|---|---:|
| Passed | true |
| Completed steps | 5 / 5 |
| Total duration | 443.988 s |
| Raw production duration | 437.7 s |

Raw proof gate summary:

| Metric | runtime_default | priority_warm_disk_restore |
|---|---:|---:|
| Result | pass | pass |
| Failure reasons | 0 | 0 |
| Startup completed | true | true |
| Startup elapsed | 96,390.541 ms | 96,840.929 ms |
| World-bake backend | native | native |
| World-bake generation | 19,629.406 ms | 28,489.528 ms |
| World-bake hash | 2,567.046 ms | 2,620.723 ms |
| Runtime idle ratio | 1.000 | 1.000 |
| Runtime busy samples | 0 | 0 |
| Town-entry ready-resource restore delta | 19 | 8 |
| Town-entry disk-hit delta | 0 | 0 |

The pre-fix command enforced
`--min-terrain-artifact-ready-resource-restore-delta 1`. That is the current
sidecar proof gate. It verifies finalization restored ready mesh/collision
resources from artifact data instead of rebuilding the `ArrayMesh` and collision
shape from deferred arrays.

The disk artifact format is now split deliberately:

```text
.agent/town-stall-appdata/Godot/app_userdata/Horror Survival Game Project/terrain_artifacts/<settings-signature-sha256>/<chunk_x>_<chunk_y>_<chunk_z>.var
.agent/town-stall-appdata/Godot/app_userdata/Horror Survival Game Project/terrain_artifacts/<settings-signature-sha256>/<chunk_x>_<chunk_y>_<chunk_z>_terrain_mesh.res
.agent/town-stall-appdata/Godot/app_userdata/Horror Survival Game Project/terrain_artifacts/<settings-signature-sha256>/<chunk_x>_<chunk_y>_<chunk_z>_terrain_shape.res
```

The `.var` payload remains binary and object-free so the async artifact writer
does not move Godot `Resource` objects across worker boundaries. Ready
`ArrayMesh` and `ConcavePolygonShape3D` resources are saved as `.res` sidecars,
and the artifact result stores `mesh_resource_path` and `shape_resource_path`.
Finalization loads those sidecars on the main thread and sets the material,
mesh, and collision shape directly.

The proof sandbox from that run contained `1,525` `.var` payloads and `754`
`.res` sidecars. The earlier embedded-resource attempt crashed during
production startup, so the object-free `.var` plus sidecar `.res` design is the
correct implementation direction. However, a later audit found that preparing a
sidecar artifact twice could remove sidecars from an already-sanitized payload.
The artifact schema was bumped to `3`, disk preparation is now idempotent for
already-prepared sidecar paths, and session artifacts are no longer forced
through disk sanitization when only the session cache needs them.

Current post-fix contract evidence:

- `addons/tests/terrain_artifact_disk_store_test.gd`: pass. Covers object-free
  `.var` payloads, loadable `.res` sidecars, and already-prepared sidecar
  payloads surviving a second store.
- `addons/tests/terrain_generation_telemetry_test.gd`: pass. Covers in-memory
  session artifacts keeping ready resources, disk artifacts restoring after the
  session cache is cleared, and finalization loading ready mesh/collision
  sidecars by path.

The strict post-fix production proof with both
`--min-terrain-artifact-cache-disk-hit-delta 1` and
`--min-terrain-artifact-ready-resource-restore-delta 1` is now accepted by the
June 11 `priority_warm_disk_restore` run recorded above:

- `.agent/gpu-telemetry/town_stall_raw_baseline_20260611_101404.json`

That run reports `disk_hit_count = 18` and
`ready_resource_restore_count = 20` in the town-entry proof phase.

Remaining limitation: this does not remove every startup terrain cost. The
current restore path still recreates GPU density/material buffers for restored
chunks. Any compute-shader or async-readback work should target the remaining
measured cache-miss/GPU-buffer cost, not the already-closed mesh/collision
materialization path.

## Remaining Cleanup

The roadmap is now past production evidence and into cleanup/classification.
The latest readiness audit still reports `125` post-evidence cleanup candidates:

| Candidate kind | Count |
|---|---:|
| rollout_or_tuning_override | 97 |
| test_hook_marker | 20 |
| test_or_isolation_hook | 8 |

Next actions:

- Promote production-safe tuning overrides into documented defaults or project
  settings.
- Remove or move isolation hooks into harness-only code.
- Review `_for_test` markers and keep only those that are part of stable test
  contracts.
- Classify the sidecar mesh/collision artifact rollout hooks, then decide
  whether the remaining GPU density/material buffer recreation is worth a
  separate optimization.
- Use the accepted cache-miss telemetry to decide the GPU sync/readback A/B
  experiment instead of adding compute-shader work speculatively.
- Keep this evidence file and the JSON artifacts as the production acceptance
  checkpoint for the current priority.
