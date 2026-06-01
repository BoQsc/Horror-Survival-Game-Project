@echo off
setlocal

REM Locked Town Baseline V1.
REM This is the only town watt/FPS launcher to use for code comparisons.
REM See addons\tests\TOWN_BASELINE_V1.md for acceptance criteria.

cd /d "%~dp0\..\.."

echo Checking for existing Godot/town-stall/Python processes...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$p = Get-Process | Where-Object { $_.ProcessName -match 'godot|town-stall|python' }; $p | Select-Object Id,ProcessName,StartTime,Path; if ($p) { exit 1 }"
if errorlevel 1 (
    echo Existing Godot/town-stall/Python process found. Close it before launching Baseline V1.
    exit /b 2
)

set TOWN_STALL_ALLOW_CONTAMINATED_IDLE=1
set TOWN_STALL_PERIODIC_HOLD_SNAPSHOTS=0
set TOWN_STALL_PERIODIC_PREHOLD_SNAPSHOTS=0
set TOWN_STALL_ENABLE_RUNTIME_POWER_MODE=1
set TOWN_STALL_RUNTIME_POWER_ACTIVE_FPS=60
set TOWN_STALL_RUNTIME_POWER_IDLE_FPS=60
set TOWN_STALL_RUNTIME_POWER_DEEP_IDLE_FPS=60

python -B addons\tests\run_town_stall_raw_baseline.py --cases runtime_deepidle60 --repeats 1 --hold-seconds 60 --idle-seconds 15 --sample-interval 1 --allow-contaminated-idle --max-gpu-temp-c 84 --preflight-max-gpu-temp-c 64 --preflight-cooldown-timeout-seconds 600 --preflight-cooldown-poll-seconds 15

endlocal
