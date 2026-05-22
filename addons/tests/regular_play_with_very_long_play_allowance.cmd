@echo off
pushd "%~dp0"

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
set TOWN_STALL_SYSTEM_SAMPLE_RAW_GPU_ONLY=1
set TOWN_STALL_ALLOW_CONTAMINATED_IDLE=1
set TOWN_STALL_DISABLE_POSTRUN_IDLE_CHECK=1

:: --- Warmup Logic ---
set TOWN_STALL_MACHINE_WARMUP_DISABLED=1
set TOWN_STALL_RENDER_DISTANCE=10


:: --- Execution ---
echo Starting long-duration test...
:: 'start /high' ensures Windows gives Python CPU priority
start "Town Stall Regular Play" /high python -u run_town_stall_test.py
pause
