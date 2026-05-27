@echo off
setlocal
pushd "%~dp0"

echo Checking for existing Godot/town-stall processes...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$p = Get-Process | Where-Object { $_.ProcessName -match 'godot|town-stall' }; $p | Select-Object Id,ProcessName,StartTime,Path; if ($p) { exit 1 }"
if errorlevel 1 (
    echo Existing Godot/town-stall process found. Close it before launching this run.
    popd
    exit /b 2
)

:: Reproduces the controlled stream-ready town run from 2026-05-27.
:: This launcher is meant to diagnose whether the stationary hold starts only
:: after terrain/building/vegetation stream and render-prewarm work is drained.
set TOWN_STALL_SEED=12345
set TOWN_STALL_AUTO_TELEPORT=0
set TOWN_STALL_MEASURE_FULL_FLIGHT=1
set TOWN_STALL_RENDER_DISTANCE=10
set TOWN_STALL_HOLD_SECONDS=20

:: Test-only loading guards.
set TOWN_STALL_TERRAIN_COLLISION_GROUND_CENTER=1
set TOWN_STALL_TERRAIN_FORCE_PENDING_NODE_FINALIZATION=1
set TOWN_STALL_TERRAIN_FORCE_STREAM_PROGRESS=1
set TOWN_STALL_WAIT_STREAM_READY_BEFORE_HOLD=1

:: Telemetry cadence from the last controlled run.
set TOWN_STALL_SYSTEM_SAMPLE_INTERVAL_SECONDS=1
set TOWN_STALL_SYSTEM_SAMPLE_RAW_GPU_ONLY=0
set TOWN_STALL_SYSTEM_SAMPLE_FULL_EVERY=5
set TOWN_STALL_MACHINE_WARMUP_DISABLED=1

:: Abort only on prolonged severe stalls; do not hide ordinary over-budget frames.
set TOWN_STALL_LOW_FPS_ABORT=1
set TOWN_STALL_LOW_FPS_ABORT_FRAME_MS=80
set TOWN_STALL_LOW_FPS_ABORT_SECONDS=4

echo Starting stream-ready 20s town hold test at normal process priority...
python -u run_town_stall_test.py
set EXIT_CODE=%ERRORLEVEL%
popd
pause
exit /b %EXIT_CODE%
