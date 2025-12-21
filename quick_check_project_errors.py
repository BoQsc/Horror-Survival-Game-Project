import subprocess
import sys
import time

# Configuration
GODOT_BIN = r"C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe"
PROJECT_PATH = r"C:\Users\Windows10_new\Documents\gpu-marching-cubes"
TIMEOUT = 3  # Seconds to run

def main():
    print(f"🚀 Running Godot for {TIMEOUT}s...")
    print("-" * 50)
    
    cmd = [
        GODOT_BIN,
        "--path", PROJECT_PATH,
        "--debug"
    ]
    
    try:
        process = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, # Merge stderr into stdout
            text=True,
            encoding='utf-8',
            errors='replace',
            bufsize=1
        )
        
        start_time = time.time()
        
        while True:
            # Check for timeout
            if time.time() - start_time > TIMEOUT:
                print(f"\n🛑 Time limit reached ({TIMEOUT}s). Terminating...")
                process.terminate()
                break
            
            # Non-blocking read
            output = process.stdout.readline()
            if output == '' and process.poll() is not None:
                break
            
            if output:
                # Print to console
                sys.stdout.write(output)
                sys.stdout.flush()
                
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            
    except Exception as e:
        print(f"❌ Execution error: {e}")

if __name__ == "__main__":
    main()
