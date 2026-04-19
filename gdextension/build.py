
import subprocess
import sys

def build():
    print("Building GDExtension...")

    # Reuse the prebuilt godot-cpp bindings instead of rebuilding them.
    # The extension itself still rebuilds incrementally when its sources change.
    scons_args = ["build_library=no"]

    # Check if scons is installed.
    try:
        subprocess.run(["scons", "--version"], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        cmd = ["scons", *scons_args]
    except Exception:
        # Fallback to python module
        print("'scons' command not found, trying 'python -m SCons'...")
        cmd = [sys.executable, "-m", "SCons", *scons_args]

    # Run build
    try:
        subprocess.check_call(cmd)
        print("\nBuild SUCCESS!")
    except subprocess.CalledProcessError as e:
        print(f"\nBuild FAILED with error code {e.returncode}")
        print("Ensure you have SCons installed (pip install scons) and the Zig compiler is setup correctly.")

if __name__ == "__main__":
    build()
