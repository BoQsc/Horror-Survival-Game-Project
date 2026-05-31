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

:: Power-safe manual long-play run.
:: Active gameplay still targets 60 FPS with Vulkan/Forward+ and render distance 10.
:: If the player leaves the game unattended, runtime power mode can drop to
:: deep idle and suspend rendering instead of redrawing the static scene forever.
set TOWN_STALL_SEED=12345
set TOWN_STALL_AUTO_TELEPORT=0
set TOWN_STALL_DISABLE_VEGETATION_RENDER=0

:: Test-only loading guards: measure full streamed terrain, not a half-loaded scene.
set TOWN_STALL_TERRAIN_COLLISION_GROUND_CENTER=1
set TOWN_STALL_TERRAIN_FORCE_PENDING_NODE_FINALIZATION=1
set TOWN_STALL_TERRAIN_FORCE_STREAM_PROGRESS=1

set TOWN_STALL_HOLD_SECONDS=9999
set TOWN_STALL_SYSTEM_SAMPLE_INTERVAL_SECONDS=1
set TOWN_STALL_SYSTEM_SAMPLE_RAW_GPU_ONLY=0
set TOWN_STALL_SYSTEM_SAMPLE_FULL_EVERY=5
set TOWN_STALL_PERIODIC_HOLD_SNAPSHOTS=1
set TOWN_STALL_WAIT_STREAM_READY_BEFORE_HOLD=1
set TOWN_STALL_ALLOW_CONTAMINATED_IDLE=1
set TOWN_STALL_DISABLE_POSTRUN_IDLE_CHECK=1
set TOWN_STALL_LOW_FPS_ABORT=1
set TOWN_STALL_LOW_FPS_ABORT_FRAME_MS=80
set TOWN_STALL_LOW_FPS_ABORT_SECONDS=4

:: Thermal safety for unattended idle. This is not a substitute for active
:: 60 FPS render optimization; it only prevents idle burn while nothing moves.
set TOWN_STALL_ENABLE_RUNTIME_POWER_MODE=1
set TOWN_STALL_RUNTIME_POWER_ACTIVE_FPS=60
set TOWN_STALL_RUNTIME_POWER_IDLE_FPS=60
set TOWN_STALL_RUNTIME_POWER_DEEP_IDLE_FPS=30
set TOWN_STALL_RUNTIME_POWER_IDLE_DELAY_S=1.25
set TOWN_STALL_RUNTIME_POWER_DEEP_IDLE_DELAY_S=10
set TOWN_STALL_RUNTIME_POWER_SUSPEND_BACKGROUND_WORLD_WORK=1
set TOWN_STALL_RUNTIME_POWER_SUSPEND_RENDER_LOOP=1
set TOWN_STALL_RUNTIME_POWER_ALLOW_UNATTENDED_RENDER_SUSPEND=1

set TOWN_STALL_MACHINE_WARMUP_DISABLED=1
set TOWN_STALL_RENDER_DISTANCE=10

echo Starting power-safe long-duration test at normal process priority...
python -u run_town_stall_test.py
set EXIT_CODE=%ERRORLEVEL%
popd
pause
exit /b %EXIT_CODE%
