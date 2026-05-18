import subprocess
import os
import sys

TESTS_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "addons", "tests")
if TESTS_PATH not in sys.path:
    sys.path.insert(0, TESTS_PATH)

from windows_error_dialogs import suppress_windows_error_dialogs

# Configuration from environment
GODOT_BIN = r"C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe"
PROJECT_PATH = os.path.dirname(os.path.abspath(__file__))
DEFAULT_SCENE = "world_map_generator/world_map_generator_ui.tscn"

def launch(scene_path=DEFAULT_SCENE, mode="play"):
    """
    Launches a specific Godot scene.
    Modes:
    - 'play': Default clean run (no debugger).
    - 'debug': Runs with the --debug flag (like F6 in editor).
    - 'edit': Opens the scene in the Godot Editor (-e).
    """
    cmd = [GODOT_BIN, "--path", PROJECT_PATH]
    
    if mode == "edit":
        cmd.append("-e")
    elif mode == "debug":
        cmd.append("--debug")
        
    cmd.append(scene_path)
    
    print(f"[Launcher] Launching {scene_path} in {mode.upper()} mode...")
    
    try:
        suppress_windows_error_dialogs()
        # Popen to launch without blocking, detached from this script
        subprocess.Popen(cmd, creationflags=subprocess.DETACHED_PROCESS | subprocess.CREATE_NEW_PROCESS_GROUP)
    except Exception as e:
        print(f"Error launching Godot: {e}")

if __name__ == "__main__":
    mode = "play" # Default matches your request (no debug)
    scene = DEFAULT_SCENE
    
    args = sys.argv[1:]
    
    # Simple flag parsing
    if "--debug" in args:
        mode = "debug"
    if "--edit" in args or "-e" in args:
        mode = "edit"
        
    # Find any custom scene path (last argument that isn't a flag)
    for arg in args:
        if not arg.startswith("-"):
            scene = arg
            
    launch(scene, mode)
