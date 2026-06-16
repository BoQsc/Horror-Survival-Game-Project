# Town Baseline V1

This is the locked baseline for town FPS and wattage work on this branch.

Use this baseline for code comparisons. Do not use older town launcher shortcuts,
manual play sessions, render ablation matrices, or periodic snapshot runs as the
main baseline.

## Official Launcher

Run from the repository root:

```powershell
addons\tests\run_locked_town_baseline_v1.cmd
```

The launcher uses:

- Vulkan / Forward+
- town render distance `10`
- `runtime_deepidle60`
- runtime power target FPS `60/60/60`
- periodic hold snapshots off
- one 60 second measured hold
- raw `nvidia-smi` power sampling
- GPU thermal guard at `84 C`
- GPU preflight cooldown disabled by default

The launcher runs with warning-only cleanliness guards by default because strict
CPU/process preflight checks have been noisy on this machine. Set
`TOWN_STALL_STRICT_LAUNCH_GUARDS=1` or `TOWN_STALL_ALLOW_CONTAMINATED_IDLE=0`
to restore fatal preflight behavior for controlled comparisons.

## Acceptance Criteria

A run is a valid Baseline V1 comparison only when all of these are true:

- return code is `0`
- `valid_run_count` is `1`
- no `failure_reasons`
- no invalid content reasons
- hold gate reaches the stable town hold
- no thermal abort
- `TOWN_STALL_PERIODIC_HOLD_SNAPSHOTS=0`
- contamination summary reports initial and final idle clean for clean code comparisons

## Locked Result

Current locked artifact:

```text
C:\Users\Windows10_new\Documents\gpu-marching-cubes\.agent\gpu-telemetry\town_stall_raw_baseline_20260601_143119.json
```

Baseline V1 result:

```text
average_fps:              59.946
hold_power_w:             31.498
stationary_hold_power_w:  31.529
moving_entry_power_w:     28.701
last20_power_w:           31.559
avg_frame_ms:             16.682
max_frame_ms:             28.822
frames_over_40ms:         0
frames_over_50ms:         0
max_gpu_temp_c:           70
periodic_hold_snapshots:  0
```

## Manual Play

Manual play is useful for feel, movement wattage, and thermal behavior. It is
not the official code comparison baseline.

Use:

```powershell
addons\tests\run_manual_town_play_no_snapshots.cmd
```

Close the Godot window when finished. Manual runs can fail the automated runner
summary if the window is closed before a final snapshot is written; use their
watt logs and play feel as supporting evidence, not as the locked baseline.

## Render Culling Audit

Use this only to answer render attribution questions. It is not the official
FPS/watt comparison baseline because it enables the final render scene scan:

```powershell
addons\tests\run_town_render_culling_audit.cmd
python -B addons\tests\analyze_render_culling_snapshot.py --latest-raw
```

The audit keeps the locked runtime rendering settings, disables periodic
snapshots, and writes one final scene scan showing which visible/frustum terrain
and vegetation batches account for submitted triangle work.

## Legacy Launchers

Older shortcuts that predate this baseline live in:

```text
addons\tests\legacy_launchers\
```

They are kept for reference only. Do not use them to decide whether FPS or watts
regressed.
