import subprocess
import os
import sys
import time

# ================= CONFIGURATION =================

# 1. Your Steam Godot Path
GODOT_BIN = r"C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe"

# 2. Your Project Folder (The folder containing project.godot)
# We strip the file name to get the root directory
PROJECT_PATH = r"C:\Users\Windows10_new\Documents\gpu-marching-cubes"

# 3. (Optional) If you ONLY want to check 'main_game_scene.tscn', uncomment the line below.
# If left as None, it will scan the whole folder and check EVERY scene.
SPECIFIC_SCENE = "main_game_scene.tscn" 
# SPECIFIC_SCENE = None

# 4. How long to test the scene (seconds)
TEST_DURATION = 3.0

# Log file (Saved in the script's folder)
LOG_FILE = "automation.log"
RUNNER_SCRIPT = os.path.join(PROJECT_PATH, "temp_automation_runner.gd")
RUNNER_SCENE_FILE = os.path.join(PROJECT_PATH, "temp_automation_runner.tscn")

# Errors to ignore (Headless mode noise)
IGNORE_LOG_ERRORS = [
    "AudioServer", "X11", "DisplayServer", "Vulkan",
    "Condition \"!windows.has(p_window)\""
]

# ================= GDSCRIPT RUNNER =================
# ================= GDSCRIPT RUNNER =================
GD_SCRIPT_CONTENT = f"""
extends Node

var _time_limit = {TEST_DURATION}
var _timer = 0.0

func _ready():
    print("--- Runner Started ---")
    var args = OS.get_cmdline_args()
    var scene_path = ""
    
    # Simple argument parsing to find the .tscn file to test
    # Godot passes a lot of engine args, so we look for the one finishing with .tscn
    # that IS NOT our runner scene.
    for arg in args:
        if arg.ends_with(".tscn") and not "temp_automation_runner.tscn" in arg:
            scene_path = arg
            break
            
    if scene_path == "":
        printerr("ERROR: No scene provided via command line.")
        get_tree().quit(1)
        return

    print("Loading scene: " + scene_path)
    var scene_res = load(scene_path)
    if scene_res == null:
        printerr("FATAL: Could not load scene: " + scene_path)
        get_tree().quit(1)
        return

    var scene_inst = scene_res.instantiate()
    get_tree().root.call_deferred("add_child", scene_inst)

func _process(delta):
    _timer += delta
    if _timer > _time_limit:
        print("--- SUCCESS: Scene ran safely ---")
        get_tree().quit(0)
"""

TSCN_CONTENT = """[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://temp_automation_runner.gd" id="1"]

[node name="Runner" type="Node"]
script = ExtResource("1")
"""

# ================= UTILITIES =================

def create_runner_script():
    try:
        with open(RUNNER_SCRIPT, "w") as f:
            f.write(GD_SCRIPT_CONTENT)
        with open(RUNNER_SCENE_FILE, "w") as f:
            f.write(TSCN_CONTENT)
    except PermissionError:
        print(f"❌ Error: Cannot write to runner files. Check permissions.")
        sys.exit(1)

def delete_runner_script():
    if os.path.exists(RUNNER_SCRIPT):
        os.remove(RUNNER_SCRIPT)
    if os.path.exists(RUNNER_SCENE_FILE):
        os.remove(RUNNER_SCENE_FILE)

def find_scenes():
    # If a specific scene is requested in CONFIG, only return that one
    if SPECIFIC_SCENE:
        full_path = os.path.join(PROJECT_PATH, SPECIFIC_SCENE)
        if os.path.exists(full_path):
            return ["res://" + SPECIFIC_SCENE]
        else:
            print(f"❌ Error: Could not find specific scene: {full_path}")
            sys.exit(1)

    # Otherwise, scan the folder
    scenes = []
    print(f"🔍 Scanning {PROJECT_PATH} for scenes...")
    for root, dirs, files in os.walk(PROJECT_PATH):
        dirs[:] = [d for d in dirs if d not in ["addons", ".godot"]]
        for file in files:
            if file.endswith(".tscn"):
                full_path = os.path.join(root, file)
                rel_path = os.path.relpath(full_path, PROJECT_PATH)
                res_path = "res://" + rel_path.replace("\\", "/")
                scenes.append(res_path)
    return scenes

def analyze_logs():
    if not os.path.exists(LOG_FILE): return False, ["Log file missing"]
    
    errors = []
    try:
        with open(LOG_FILE, "r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                if "ERROR:" in line or "SCRIPT ERROR:" in line or "FATAL:" in line:
                    if not any(ign in line for ign in IGNORE_LOG_ERRORS):
                        errors.append(line.strip())
    except Exception as e:
        return False, [str(e)]
    
    return (len(errors) > 0), errors

def run_scene(scene_path):
    print(f"🎬 Testing: {scene_path} ...", end=" ", flush=True)
    
    if os.path.exists(LOG_FILE): 
        try: os.remove(LOG_FILE)
        except: pass

    # Convert absolute path for runner script to be safe
    runner_scene_rel = "res://temp_automation_runner.tscn"

    cmd = [
        GODOT_BIN,
        "--headless",
        "--path", PROJECT_PATH,
        runner_scene_rel,
        # Pass the target scene as an argument. 
        # Note: In scene mode, arguments are passed weirdly, but usually just appending works for get_cmdline_args
        scene_path,
        "--log-file", os.path.abspath(LOG_FILE)
    ]

    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=TEST_DURATION + 10)
        
        if result.returncode != 0:
            print(f"❌ CRASHED (Exit Code: {result.returncode})")
            return False

        has_error, details = analyze_logs()
        if has_error:
            print("❌ ERRORS FOUND")
            for err in details: print(f"    └─ {err}")
            return False
            
        print("✅ OK")
        return True

    except subprocess.TimeoutExpired:
        print("❌ TIMEOUT (Frozen)")
        return False

# ================= MAIN =================

if __name__ == "__main__":
    if not os.path.exists(GODOT_BIN):
        print("❌ Godot executable not found.")
        sys.exit(1)

    create_runner_script()
    scenes = find_scenes()
    
    if not scenes:
        print("❌ No scenes found.")
        delete_runner_script()
        sys.exit(1)

    print(f"🚀 Starting Test Run on {len(scenes)} scene(s)...")
    print("-" * 40)

    failed = []
    try:
        for scene in scenes:
            if not run_scene(scene):
                failed.append(scene)
    finally:
        delete_runner_script()

    print("-" * 40)
    if failed:
        print(f"💀 FAILED SCENES ({len(failed)}):")
        for s in failed: print(f" - {s}")
    else:
        print("🎉 SUCCESS: All scenes passed.")