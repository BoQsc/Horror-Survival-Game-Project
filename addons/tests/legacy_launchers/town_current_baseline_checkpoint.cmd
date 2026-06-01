@echo off
setlocal

REM Current checkpoint launcher for the achieved town baseline configuration.
REM Scope:
REM - Vulkan / Forward+ through run_town_stall_test.py
REM - render distance 10 from the town test harness
REM - runtime power manager enabled
REM - event-driven interaction/save telemetry enabled in current code
REM - watts/FPS measured by raw nvidia-smi wrapper
REM
REM This is not a manual gameplay launcher and not a renderer workaround.
REM It runs one 40s measured town hold using the current runtime_default case.

cd /d "%~dp0\..\.."

set TOWN_STALL_ALLOW_CONTAMINATED_IDLE=1

python -u addons\tests\run_town_stall_raw_baseline.py --cases runtime_default --repeats 1 --hold-seconds 40 --idle-seconds 20 --sample-interval 1 --allow-contaminated-idle

endlocal
