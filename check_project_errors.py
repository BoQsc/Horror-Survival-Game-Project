import subprocess
import sys
import time

# Configuration
GODOT_BIN = r"C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe"
PROJECT_PATH = r"C:\Users\Windows10_new\Documents\gpu-marching-cubes"
TIMEOUT = 3  # Seconds to run

def main():
    print(f"🚀 Running Godot for {TIMEOUT}s (Unfiltered Output)...")
    print("-" * 50)
    
    cmd = [
        GODOT_BIN,
        "--path", PROJECT_PATH,
        "--debug"
    ]
    
    try:
        # Stream output directly to console
        process = subprocess.Popen(
            cmd,
            stdout=sys.stdout,
            stderr=sys.stderr,
            text=True,
            encoding='utf-8',
            errors='replace'
        )
        
        try:
            process.wait(timeout=TIMEOUT)
        except subprocess.TimeoutExpired:
            print("-" * 50)
            print(f"🛑 Time limit reached ({TIMEOUT}s). Terminating...")
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                
    except Exception as e:
        print(f"❌ Execution error: {e}")

if __name__ == "__main__":
    main()
