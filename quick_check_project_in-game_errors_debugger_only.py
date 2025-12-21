import subprocess
import sys
import os
import re

# Configuration
GODOT_BIN = r"C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe"
PROJECT_PATH = r"C:\Users\Windows10_new\Documents\gpu-marching-cubes"
TIMEOUT = 20  # Seconds to run
RAW_LOG_FILE = "raw_output.txt"

def main():
    print(f"🚀 Running Godot for {TIMEOUT}s...")
    
    cmd = [
        GODOT_BIN,
        "--path", PROJECT_PATH,
        "--debug"
    ]
    
    output = ""
    try:
        result = subprocess.run(
            cmd, 
            capture_output=True, 
            text=True, 
            timeout=TIMEOUT, 
            encoding='utf-8', 
            errors='replace'
        )
        print("✅ Process finished normally.")
        output = result.stdout + "\n" + result.stderr
    except subprocess.TimeoutExpired as e:
        print(f"🛑 Time limit reached ({TIMEOUT}s).")
        output = (e.stdout if e.stdout else "") + "\n" + (e.stderr if e.stderr else "")
    except Exception as e:
        print(f"❌ Execution error: {e}")
        return

    # Warning! Never Save raw output for inspection. It's annoying when you can now see using stdout output without saving to file.
    #with open(RAW_LOG_FILE, "w", encoding="utf-8") as f:
    #    f.write(output)
    #print(f"📄 Full output saved to: {RAW_LOG_FILE}")
    
    # Filter output
    lines = output.splitlines()
    ansi_escape = re.compile(r'\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])')
    
    print("-" * 40)
    print("🔍 SCANNING FOR ERRORS...")
    found_lines = 0
    capturing = False
    
    for raw_line in lines:
        line = ansi_escape.sub('', raw_line).strip()
        
        # Extremely permissive match: contains "error" case-insensitive
        # But exclude common false positives if any (none yet)
        is_error_start = (
            "ERROR" in line.upper() or
            "EXCEPTION" in line.upper() or
            (line.startswith("E ") and len(line) > 5 and line[2].isdigit()) or
             " <C++ Error>" in line
        )
        
        if is_error_start:
            capturing = True
            found_lines += 1
            print(raw_line)
            continue
            
        if capturing:
            if raw_line and (raw_line.startswith("   ") or raw_line.startswith("\t") or (len(raw_line)>0 and raw_line[0].isspace())):
                print(raw_line)
            else:
                capturing = False

    if found_lines == 0:
        print("❌ FILTER REPORT: No lines matched 'ERROR/EXCEPTION/E 0:00'.")
        print("   Checking first 10 lines of raw output for context:")
        for i in range(min(10, len(lines))):
            print(f"   Line {i}: {repr(lines[i])}")
    else:
        print(f"✅ Found {found_lines} error blocks.")
        
    print("-" * 40)

if __name__ == "__main__":
    main()
