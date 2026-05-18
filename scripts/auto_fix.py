import json
import subprocess
import sys
from pathlib import Path

PROJECT_PATH = Path(__file__).resolve().parents[1]
TESTS_PATH = PROJECT_PATH / "addons" / "tests"
if str(TESTS_PATH) not in sys.path:
    sys.path.insert(0, str(TESTS_PATH))

from windows_error_dialogs import suppress_windows_error_dialogs

prefab_path = PROJECT_PATH / 'world_prefabs' / 'new_wooden_house_2floor_secret_facility.json'

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
subprocess.run(
    [
        godot_exe,
        '--headless',
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
