@echo off
:: --- Environment Configuration ---
set TOWN_STALL_SEED=12345
set TOWN_STALL_AUTO_TELEPORT=1

:: --- Performance Stripping (Disable visuals/physics for long runs) ---


set TOWN_STALL_HOLD_SECONDS=9999

:: --- Warmup Logic ---
set TOWN_STALL_MACHINE_WARMUP_DISABLED=1
set TOWN_STALL_RENDER_DISTANCE=10


:: --- Execution ---
echo Starting long-duration test...
:: 'start /high' ensures Windows gives Python CPU priority
start /high python run_town_stall_test.py
pause