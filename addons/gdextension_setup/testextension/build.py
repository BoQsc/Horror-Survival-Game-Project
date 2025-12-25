#!/usr/bin/env python
"""
Build script for testextension - uses SCons with cached godot-cpp.

Usage:
    python build.py              # Debug build
    python build.py release      # Release build
"""
import os
import sys
import subprocess

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PARENT_DIR = os.path.dirname(SCRIPT_DIR)

def main():
    target = "template_release" if len(sys.argv) > 1 and sys.argv[1].lower() == "release" else "template_debug"
    
    cmd = [sys.executable, "-m", "SCons", "--jobs=4", f"target={target}", "platform=windows"]
    print(f"Building ({target})...")
    
    result = subprocess.run(cmd, cwd=PARENT_DIR)
    
    if result.returncode == 0:
        print("\nBuild successful! Output in testextension/bin/")
    sys.exit(result.returncode)

if __name__ == "__main__":
    main()
