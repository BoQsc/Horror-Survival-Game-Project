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

:: --- Environment Configuration ---
set TOWN_STALL_SEED=12345
set TOWN_STALL_AUTO_TELEPORT=0

:: --- Vegetation/render heat profile ---
set TOWN_STALL_DISABLE_VEGETATION_RENDER=0

:: --- Test-only loading guards: measure full streamed terrain, not a half-loaded scene ---
set TOWN_STALL_TERRAIN_COLLISION_GROUND_CENTER=1
set TOWN_STALL_TERRAIN_FORCE_PENDING_NODE_FINALIZATION=1
set TOWN_STALL_TERRAIN_FORCE_STREAM_PROGRESS=1

set TOWN_STALL_HOLD_SECONDS=9999
set TOWN_STALL_SYSTEM_SAMPLE_INTERVAL_SECONDS=1
set TOWN_STALL_SYSTEM_SAMPLE_RAW_GPU_ONLY=0
:: Keep 1s GPU watt samples, but avoid expensive full Windows process probes every second.
set TOWN_STALL_SYSTEM_SAMPLE_FULL_EVERY=5
:: Manual long-play runs are often closed before the 9999s hold completes.
:: Periodic snapshots preserve FPS/content telemetry from the current hold.
set TOWN_STALL_PERIODIC_HOLD_SNAPSHOTS=1
:: Do not measure stationary hold while terrain/building/vegetation stream work is still draining.
set TOWN_STALL_WAIT_STREAM_READY_BEFORE_HOLD=1
set TOWN_STALL_ALLOW_CONTAMINATED_IDLE=1
set TOWN_STALL_DISABLE_POSTRUN_IDLE_CHECK=1
set TOWN_STALL_LOW_FPS_ABORT=1
set TOWN_STALL_LOW_FPS_ABORT_FRAME_MS=80
set TOWN_STALL_LOW_FPS_ABORT_SECONDS=4
:: Keep benchmark/manual profiling at a 60 FPS target; do not let idle power
:: mode contaminate the run with a 30 FPS cap.
set TOWN_STALL_RUNTIME_POWER_IDLE_FPS=60
set TOWN_STALL_RUNTIME_POWER_DEEP_IDLE_FPS=60
set TOWN_STALL_RUNTIME_POWER_SUSPEND_RENDER_LOOP=0

:: --- Warmup Logic ---
set TOWN_STALL_MACHINE_WARMUP_DISABLED=1
set TOWN_STALL_RENDER_DISTANCE=10


:: --- Execution ---
echo Starting long-duration test at normal process priority...
python -u run_town_stall_test.py
set EXIT_CODE=%ERRORLEVEL%
popd
pause
exit /b %EXIT_CODE%
