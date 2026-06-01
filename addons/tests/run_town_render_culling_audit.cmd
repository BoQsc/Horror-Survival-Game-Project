@echo off
setlocal

REM Diagnostic town render-culling audit.
REM This is not the locked FPS/watt baseline. It runs the locked town runtime
REM settings with the existing final render scene scan enabled so we can see
REM which visible/frustum batches account for submitted primitives.

cd /d "%~dp0\..\.."

echo Checking for existing Godot/town-stall/Python processes...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$p = Get-Process | Where-Object { $_.ProcessName -match 'godot|town-stall|python' }; $p | Select-Object Id,ProcessName,StartTime,Path; if ($p) { exit 1 }"
if errorlevel 1 (
    echo Existing Godot/town-stall/Python process found. Close it before launching the render-culling audit.
    exit /b 2
)

set TOWN_STALL_ALLOW_CONTAMINATED_IDLE=1
set TOWN_STALL_PERIODIC_HOLD_SNAPSHOTS=0
set TOWN_STALL_PERIODIC_PREHOLD_SNAPSHOTS=0
set TOWN_STALL_ENABLE_RUNTIME_POWER_MODE=1
set TOWN_STALL_RUNTIME_POWER_ACTIVE_FPS=60
set TOWN_STALL_RUNTIME_POWER_IDLE_FPS=60
set TOWN_STALL_RUNTIME_POWER_DEEP_IDLE_FPS=60
set TOWN_STALL_RENDER_DIAGNOSTICS=1
set TOWN_STALL_RENDER_DIAGNOSTIC_SCENE_SCAN=1
set TOWN_STALL_RENDER_DIAGNOSTIC_THRESHOLD_MS=9999
set TOWN_STALL_RENDER_DIAGNOSTIC_LIMIT=1
set TOWN_STALL_RENDER_DIAGNOSTIC_SCENE_DETAIL_LIMIT=80
set TOWN_STALL_RENDER_DIAGNOSTIC_FRAME_SCENE_SCAN_LIMIT=1

python -B addons\tests\run_town_stall_raw_baseline.py --cases runtime_deepidle60 --repeats 1 --hold-seconds 20 --idle-seconds 10 --sample-interval 1 --allow-contaminated-idle --max-gpu-temp-c 84 --preflight-max-gpu-temp-c 64 --preflight-cooldown-timeout-seconds 600 --preflight-cooldown-poll-seconds 15

endlocal
