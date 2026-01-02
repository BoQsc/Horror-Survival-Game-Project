
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
        
        # Only stage bin folder changes on successful build
        print("\nStaging bin folder for git commit...")
        try:
            subprocess.run(["git", "add", "-f", "bin/"], check=True, shell=True)
            print("Successfully added bin/ folder to git staging area")
        except subprocess.CalledProcessError:
            print("Warning: Could not add bin/ to git (git may not be available or not a git repo)")
        except FileNotFoundError:
            print("Warning: git command not found")
            
    except subprocess.CalledProcessError as e:
        print(f"\nBuild FAILED with error code {e.returncode}")
        print("Ensure you have SCons installed (pip install scons) and the Zig compiler is setup correctly.")
        print("\nBin folder NOT staged to git (build failed)")

if __name__ == "__main__":
    build()
    input("Completed")