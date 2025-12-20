import subprocess
import sys
import os

# Configuration
GODOT_BIN = r"C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe"
PROJECT_PATH = r"C:\Users\Windows10_new\Documents\gpu-marching-cubes"
TIMEOUT = 20  # Seconds to run

def main():
    print(f"🚀 Running Godot for {TIMEOUT}s and filtering errors...")
    
    cmd = [
        GODOT_BIN,
        "--path", PROJECT_PATH,
        "--debug"
    ]
    
    output = ""
    try:
        # capture_output=True captures stdout and stderr. 
        # text=True decodes as string.
        subprocess.run(
            cmd, 
            capture_output=True, 
            text=True, 
            timeout=TIMEOUT, 
            encoding='utf-8', 
            errors='replace'
        )
        print("✅ Process finished normally (unexpected for infinite loop).")
    except subprocess.TimeoutExpired as e:
        # This is expected
        output = e.stdout if e.stdout else ""
        if e.stderr:
            output += "\n" + e.stderr
    except Exception as e:
        print(f"❌ Execution error: {e}")
        return

    # Filter output
    lines = output.splitlines()
    capturing = False
    
    print("-" * 40)
    found_errors = False
    
    for line in lines:
        # Check for start of error block
        if line.startswith("ERROR:"):
            capturing = True
            found_errors = True
            print(line)
            continue
            
        # Check for continuation (indented lines)
        if capturing:
            if line and line[0].isspace():
                print(line)
            else:
                capturing = False
    
    if not found_errors:
        print("No matches for 'ERROR:' found in captured output.")
    print("-" * 40)

if __name__ == "__main__":
    main()
