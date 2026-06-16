@echo off
setlocal
pushd "%~dp0"

echo Checking for existing Godot/town-stall processes (warning-only by default)...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$p = Get-Process | Where-Object { $_.ProcessName -match 'godot|town-stall' }; if ($p) { Write-Host 'WARNING: Existing process found; continuing because TOWN_STALL_STRICT_LAUNCH_GUARDS is not 1.'; $p | Select-Object Id,ProcessName,StartTime,Path }"
if "%TOWN_STALL_STRICT_LAUNCH_GUARDS%"=="1" (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "$p = Get-Process | Where-Object { $_.ProcessName -match 'godot|town-stall' }; if ($p) { exit 1 }"
    if errorlevel 1 (
        echo Existing Godot/town-stall process found. Close it before launching this run or unset TOWN_STALL_STRICT_LAUNCH_GUARDS.
        popd
        exit /b 2
    )
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
:: Keep this benchmark at a 60 FPS target; runtime-power deep idle otherwise
:: creates a false 30 FPS stationary hold result.
set TOWN_STALL_RUNTIME_POWER_IDLE_FPS=60
set TOWN_STALL_RUNTIME_POWER_DEEP_IDLE_FPS=60
set TOWN_STALL_RUNTIME_POWER_SUSPEND_RENDER_LOOP=0

echo Starting stream-ready 20s town hold test at normal process priority...
python -u run_town_stall_test.py
set EXIT_CODE=%ERRORLEVEL%
popd
pause
exit /b %EXIT_CODE%
