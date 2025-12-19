
import os
import subprocess
import sys

def build():
    print("Building GDExtension...")
    
    # Check if scons is installed
    try:
        # Try running scons as a command
        subprocess.run(["scons", "--version"], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, shell=True)
        cmd = ["scons"]
    except:
        # Fallback to python module
        print("'scons' command not found, trying 'python -m SCons'...")
        cmd = [sys.executable, "-m", "SCons"]

    # Run build
    try:
        subprocess.check_call(cmd, shell=True)
        print("\nBuild SUCCESS!")
    except subprocess.CalledProcessError as e:
        print(f"\nBuild FAILED with error code {e.returncode}")
        print("Ensure you have SCons installed (pip install scons) and the Zig compiler is setup correctly.")

if __name__ == "__main__":
    build()
    input("Completed")