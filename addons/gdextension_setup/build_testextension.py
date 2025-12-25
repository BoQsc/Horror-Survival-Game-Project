#!/usr/bin/env python
"""
Build script for testextension GDExtension.

Usage:
    python build_testextension.py         # Debug build
    python build_testextension.py release # Release build
    python build_testextension.py setup   # Full setup + build
"""
import os
import sys
import subprocess

# Get script directory
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

def check_prerequisites():
    """Check if all prerequisites are in place."""
    godot_cpp_dir = os.path.join(SCRIPT_DIR, "godot-cpp-godot-4.5-stable")
    zig_dir = os.path.join(SCRIPT_DIR, "zig-x86_64-windows-0.16.0-dev.1484+d0ba6642b")
    src_dir = os.path.join(SCRIPT_DIR, "testextension", "src")
    sconstruct = os.path.join(SCRIPT_DIR, "SConstruct")
    
    missing = []
    if not os.path.exists(godot_cpp_dir):
        missing.append("godot-cpp (not downloaded)")
    if not os.path.exists(zig_dir):
        missing.append("Zig compiler (not downloaded)")
    if not os.path.exists(src_dir) or not os.listdir(src_dir):
        missing.append("Source files (not created)")
    if not os.path.exists(sconstruct):
        missing.append("SConstruct file (not created)")
    
    return missing

def run_setup():
    """Run the full setup script."""
    print("=" * 60)
    print("Running full setup (download + create files + build)...")
    print("=" * 60)
    setup_script = os.path.join(SCRIPT_DIR, "setup_project.py")
    subprocess.check_call([sys.executable, setup_script], cwd=SCRIPT_DIR)

def run_build(target="template_debug"):
    """Run the SCons build."""
    print("=" * 60)
    print(f"Building testextension ({target})...")
    print("=" * 60)
    
    # Check prerequisites
    missing = check_prerequisites()
    if missing:
        print("\n[ERROR] Prerequisites missing:")
        for m in missing:
            print(f"  - {m}")
        print("\nRun 'python build_testextension.py setup' to complete setup first.")
        return False
    
    # Prepare build command
    build_cmd = [
        sys.executable, "-m", "SCons",
        "--jobs=4",
        f"target={target}",
        "platform=windows"
    ]
    
    print(f"\nRunning: {' '.join(build_cmd)}")
    print(f"Working directory: {SCRIPT_DIR}\n")
    
    try:
        subprocess.check_call(build_cmd, cwd=SCRIPT_DIR)
        print("\n" + "=" * 60)
        print("BUILD SUCCESSFUL!")
        print("=" * 60)
        
        # Show output location
        bin_dir = os.path.join(SCRIPT_DIR, "testextension", "bin")
        if os.path.exists(bin_dir):
            print("\nOutput files in:", bin_dir)
            for f in os.listdir(bin_dir):
                filepath = os.path.join(bin_dir, f)
                if os.path.isfile(filepath):
                    size = os.path.getsize(filepath)
                    print(f"  - {f} ({size:,} bytes)")
        return True
    except subprocess.CalledProcessError as e:
        print(f"\n[ERROR] Build failed with exit code {e.returncode}")
        return False

def main():
    os.chdir(SCRIPT_DIR)
    
    if len(sys.argv) < 2:
        # Default: debug build
        run_build("template_debug")
    elif sys.argv[1].lower() == "release":
        run_build("template_release")
    elif sys.argv[1].lower() == "setup":
        run_setup()
    elif sys.argv[1].lower() == "debug":
        run_build("template_debug")
    elif sys.argv[1].lower() == "check":
        missing = check_prerequisites()
        if missing:
            print("Prerequisites missing:")
            for m in missing:
                print(f"  - {m}")
            print("\nRun 'python build_testextension.py setup' to complete setup.")
        else:
            print("All prerequisites are in place. Ready to build!")
    else:
        print(__doc__)
        sys.exit(1)

if __name__ == "__main__":
    main()
