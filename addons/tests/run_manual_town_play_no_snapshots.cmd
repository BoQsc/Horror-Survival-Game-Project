@echo off
setlocal

REM Manual town play launcher aligned with Baseline V1 settings.
REM This is for play feel, movement watts, and thermal behavior.
REM It is not the official code comparison baseline.

cd /d "%~dp0\..\.."

echo Checking for existing Godot/town-stall/Python processes (warning-only by default)...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$p = Get-Process | Where-Object { $_.ProcessName -match 'godot|town-stall|python' }; if ($p) { Write-Host 'WARNING: Existing process found; continuing because TOWN_STALL_STRICT_LAUNCH_GUARDS is not 1.'; $p | Select-Object Id,ProcessName,StartTime,Path }"
if "%TOWN_STALL_STRICT_LAUNCH_GUARDS%"=="1" (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "$p = Get-Process | Where-Object { $_.ProcessName -match 'godot|town-stall|python' }; if ($p) { exit 1 }"
    if errorlevel 1 (
        echo Existing Godot/town-stall/Python process found. Close it before launching manual play or unset TOWN_STALL_STRICT_LAUNCH_GUARDS.
        exit /b 2
    )
)

set TOWN_STALL_ALLOW_CONTAMINATED_IDLE=1
set TOWN_STALL_PERIODIC_HOLD_SNAPSHOTS=0
set TOWN_STALL_PERIODIC_PREHOLD_SNAPSHOTS=0
set TOWN_STALL_ENABLE_RUNTIME_POWER_MODE=1
set TOWN_STALL_RUNTIME_POWER_ACTIVE_FPS=60
set TOWN_STALL_RUNTIME_POWER_IDLE_FPS=60
set TOWN_STALL_RUNTIME_POWER_DEEP_IDLE_FPS=60
set TOWN_STALL_HOLD_SECONDS=900
set TOWN_STALL_TIMEOUT_SECONDS=1250
set TOWN_STALL_MEASURE_FULL_FLIGHT=0
set TOWN_STALL_DISABLE_POSTRUN_IDLE_CHECK=1
set TOWN_STALL_SYSTEM_SAMPLE_INTERVAL_SECONDS=1
set TOWN_STALL_SYSTEM_SAMPLE_RAW_GPU_ONLY=1

python -B addons\tests\run_town_stall_test.py

endlocal
