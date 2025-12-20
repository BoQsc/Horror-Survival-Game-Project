import subprocess
import time
import os
import signal

# Configuration
GODOT_BIN = r"C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe"
PROJECT_PATH = r"C:\Users\Windows10_new\Documents\gpu-marching-cubes"
LOG_FILE = "simple_run_verify.log"
TIMEOUT = 10  # Seconds to run

def main():
    print(f"🚀 Launching Godot Project for {TIMEOUT} seconds...")
    print(f"   Log file: {LOG_FILE}")
    
    cmd = [
        GODOT_BIN,
        "--path", PROJECT_PATH,
        "--debug"
    ]

    try:
        # Start Godot process
        process = subprocess.Popen(cmd)
        
        # Wait for the specified duration
        time.sleep(TIMEOUT)
        
        print("🛑 Time limit reached. Terminating Godot process...")
        
        # Terminate the process
        if process.poll() is None: # If still running
            process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                print("   Forcing kill...")
                process.kill()
        
        print("✅ Done.")

    except FileNotFoundError:
        print(f"❌ Error: Godot executable not found at '{GODOT_BIN}'")
    except Exception as e:
        print(f"❌ An error occurred: {e}")

if __name__ == "__main__":
    main()