@echo off
setlocal

REM Diagnostic town probe for camera-dependent render cost.
REM Keeps Vulkan / Forward+ through the normal town harness and render distance 10.
REM During the measured hold, the harness rotates the camera through fixed directions
REM and records per-direction FPS/draw/primitives in the performance snapshot.
REM Entities are disabled here so spawn stabilization cannot block the render probe.

cd /d "%~dp0\..\.."

set TOWN_STALL_ALLOW_CONTAMINATED_IDLE=1
set TOWN_STALL_DISABLE_ENTITIES=1
set TOWN_STALL_DIRECTIONAL_RENDER_SAMPLING=1
set TOWN_STALL_DIRECTIONAL_RENDER_SAMPLE_SECONDS=4
set TOWN_STALL_DIRECTIONAL_RENDER_SETTLE_SECONDS=0.75
set TOWN_STALL_PERIODIC_PREHOLD_SNAPSHOTS=1
set TOWN_STALL_PREHOLD_SNAPSHOT_INTERVAL_SECONDS=5
set TOWN_STALL_PREFLIGHT_MAX_GPU_TEMP_C=68
set TOWN_STALL_PREFLIGHT_COOLDOWN_TIMEOUT_SECONDS=420
set TOWN_STALL_PREFLIGHT_COOLDOWN_POLL_SECONDS=15

python -u addons\tests\run_town_stall_raw_baseline.py --cases runtime_default --repeats 1 --hold-seconds 32 --idle-seconds 15 --sample-interval 1 --allow-contaminated-idle --max-gpu-temp-c 86 --preflight-max-gpu-temp-c 68 --preflight-cooldown-timeout-seconds 420 --preflight-cooldown-poll-seconds 15

endlocal
