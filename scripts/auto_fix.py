import json
import subprocess
import sys
from pathlib import Path

PROJECT_PATH = Path(__file__).resolve().parents[1]
TESTS_PATH = PROJECT_PATH / "addons" / "tests"
if str(TESTS_PATH) not in sys.path:
    sys.path.insert(0, str(TESTS_PATH))

from windows_error_dialogs import suppress_windows_error_dialogs
import run_town_stall_test as town_runner

prefab_path = PROJECT_PATH / 'world_prefabs' / 'new_wooden_house_2floor_secret_facility.json'
GODOT_RENDERING_DRIVER = 'vulkan'
GODOT_RENDERING_METHOD = 'forward_plus'

with open(prefab_path, 'r') as f:
    d = json.load(f)

layers = []
c = []
for l in d['layers']:
    if l == '---':
        layers.append(c)
        c = []
    else:
        c.append(l)
layers.append(c)

def set_x67(y, z, val):
    parts = layers[y][z].strip().split()
    parts[6] = val
    parts[7] = val
    layers[y][z] = " ".join(parts)

# Layer 6
set_x67(6, 7, "[4]")
set_x67(6, 8, ".")

# Layer 7 (Foundation)
set_x67(7, 7, ".")
set_x67(7, 8, "[4]")
set_x67(7, 9, "[1]")

# Layer 8 (House Interior)
set_x67(8, 7, ".")
set_x67(8, 8, ".")

out_layers = []
for i, l in enumerate(layers):
    out_layers.extend(l)
    if i < len(layers) - 1:
        out_layers.append("---")
        
d['layers'] = out_layers
with open(prefab_path, 'w') as f:
    json.dump(d, f, indent='\t')

godot_exe = 'C:\\Program Files (x86)\\Steam\\steamapps\\common\\Godot Engine\\godot.windows.opt.tools.64.exe'
suppress_windows_error_dialogs()
running_processes = town_runner._find_running_godot_processes()
if running_processes:
    print('ERROR: A Godot process is already running. Refusing to launch validation.')
    sys.exit(2)
subprocess.run(
    [
        godot_exe,
        '--headless',
        '--rendering-driver',
        GODOT_RENDERING_DRIVER,
        '--rendering-method',
        GODOT_RENDERING_METHOD,
        '--path',
        str(PROJECT_PATH),
        '-s',
        'scripts/test_validation.gd',
    ],
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
    cwd=PROJECT_PATH,
)

with open(PROJECT_PATH / 'validation_output.txt', 'r') as f:
    val = json.load(f)

print(f"Valid: {val['valid_for_spawn']}, Errors: {val.get('errors', [])}, Warnings: {val.get('warnings', [])}")
