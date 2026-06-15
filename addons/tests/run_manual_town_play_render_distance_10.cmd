@echo off
setlocal

REM Manual town play launcher for the current render-distance-10 priority check.
REM This hands control to the player after world generation and town arrival.

cd /d "%~dp0\..\.."

echo Checking for existing Godot/town-stall test processes...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$p = Get-CimInstance Win32_Process | Where-Object { $_.Name -match 'godot|town-stall' -or ($_.Name -match 'python' -and $_.CommandLine -match 'run_town_stall') }; $p | Select-Object ProcessId,Name,CreationDate,CommandLine; if ($p) { exit 1 }"
if errorlevel 1 (
    echo Existing Godot/town-stall test process found. Close it before launching manual play.
    exit /b 2
)

set TOWN_STALL_ALLOW_CONTAMINATED_IDLE=1
set TOWN_STALL_PERIODIC_HOLD_SNAPSHOTS=0
set TOWN_STALL_PERIODIC_PREHOLD_SNAPSHOTS=0
set TOWN_STALL_ENABLE_RUNTIME_POWER_MODE=1
set TOWN_STALL_RUNTIME_POWER_ACTIVE_FPS=60
set TOWN_STALL_RUNTIME_POWER_IDLE_FPS=60
set TOWN_STALL_RUNTIME_POWER_DEEP_IDLE_FPS=60
set TOWN_STALL_RENDER_DISTANCE=10
set TOWN_STALL_TERRAIN_RENDER_DISTANCE=10
set TOWN_STALL_BUILDING_RENDER_DISTANCE=10
set TOWN_STALL_HOLD_SECONDS=900
set TOWN_STALL_TIMEOUT_SECONDS=1250
set TOWN_STALL_AUTO_TELEPORT=1
set TOWN_STALL_MEASURE_FULL_FLIGHT=0
set TOWN_STALL_MANUAL_HANDOFF=1
set TOWN_STALL_MANUAL_HANDOFF_WAIT_FOR_IDLE=0
set TOWN_STALL_DISABLE_POSTRUN_IDLE_CHECK=1
set TOWN_STALL_SYSTEM_SAMPLE_INTERVAL_SECONDS=1
set TOWN_STALL_SYSTEM_SAMPLE_RAW_GPU_ONLY=1
set TOWN_STALL_TERRAIN_ARTIFACT_STORE_SOURCE_BUFFERS=1

python -B addons\tests\run_town_stall_test.py

endlocal
