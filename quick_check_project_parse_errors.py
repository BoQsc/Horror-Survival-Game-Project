import subprocess
import sys
from pathlib import Path

GODOT_BIN = r"C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe"
PROJECT_PATH = r"C:\Users\Windows10_new\Documents\gpu-marching-cubes"
TIMEOUT = 120

SCRIPT_PATH = Path(PROJECT_PATH) / "_tmp_parse_check.gd"

CHECKER_SCRIPT = """@tool
extends SceneTree

const ROOTS := [
\t"res://"
]

func _init() -> void:
\tprint("[ParseCheck] scanning project scripts...")
\tvar files := _collect_files("res://")
\tvar loaded := 0
\tvar failed := 0
\tfor rel_path in files:
\t\tif rel_path.ends_with(".gd"):
\t\t\tloaded += 1
\t\t\tvar resource = load(rel_path)
\t\t\tif resource == null:
\t\t\t\tfailed += 1
\t\t\t\tpush_error("[ParseCheck] failed to load %s" % rel_path)
\t\telif rel_path.ends_with(".tscn") or rel_path.ends_with(".tres"):
\t\t\tloaded += 1
\t\t\tvar resource2 = load(rel_path)
\t\t\tif resource2 == null:
\t\t\t\tfailed += 1
\t\t\t\tpush_error("[ParseCheck] failed to load %s" % rel_path)
\tprint("[ParseCheck] scanned %d resources, %d failed" % [loaded, failed])
\tquit()

func _collect_files(root: String) -> Array[String]:
\tvar result: Array[String] = []
\t_collect_files_recursive(root, result)
\tresult.sort()
\treturn result

func _collect_files_recursive(root: String, result: Array[String]) -> void:
\tvar dir = DirAccess.open(root)
\tif not dir:
\t\treturn
\tdir.list_dir_begin()
\tvar name = dir.get_next()
\twhile name != "":
\t\tif name != "." and name != "..":
\t\t\tvar full_path = root.path_join(name)
\t\t\tif dir.current_is_dir():
\t\t\t\tif not full_path.begins_with("res://.godot"):
\t\t\t\t\t_collect_files_recursive(full_path, result)
\t\t\telif name.ends_with(".gd") or name.ends_with(".tscn") or name.ends_with(".tres"):
\t\t\t\tresult.append(full_path)
\t\tname = dir.get_next()
\tdir.list_dir_end()
"""


def main() -> int:
    print("🚀 Running Godot parse scan for project resources...")
    SCRIPT_PATH.write_text(CHECKER_SCRIPT, encoding="utf-8")

    cmd = [
        GODOT_BIN,
        "--headless",
        "--path",
        PROJECT_PATH,
        "--script",
        str(SCRIPT_PATH),
    ]

    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=TIMEOUT,
            encoding="utf-8",
            errors="replace",
        )
        output = (result.stdout or "") + "\n" + (result.stderr or "")
        print(output, end="")
        return result.returncode
    except subprocess.TimeoutExpired as e:
        output = (e.stdout if e.stdout else "") + "\n" + (e.stderr if e.stderr else "")
        print(output, end="")
        print(f"\n🛑 Time limit reached ({TIMEOUT}s).")
        return 124
    finally:
        try:
            SCRIPT_PATH.unlink()
        except FileNotFoundError:
            pass


if __name__ == "__main__":
    raise SystemExit(main())
