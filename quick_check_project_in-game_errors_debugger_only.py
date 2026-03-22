import subprocess
import sys
import re

# Configuration
GODOT_BIN = r"C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe"
PROJECT_PATH = r"C:\Users\Windows10_new\Documents\gpu-marching-cubes"
TIMEOUT = 20  # Seconds to run


def safe_print(text: str = "", end: str = "\n") -> None:
    sys.stdout.write(text.encode(sys.stdout.encoding or "utf-8", errors="replace").decode(sys.stdout.encoding or "utf-8"))
    sys.stdout.write(end)


def main():
    safe_print(f"Running Godot for {TIMEOUT}s...")

    cmd = [
        GODOT_BIN,
        "--path",
        PROJECT_PATH,
        "--debug",
    ]

    output = ""
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=TIMEOUT,
            encoding="utf-8",
            errors="replace",
        )
        safe_print("Process finished normally.")
        output = result.stdout + "\n" + result.stderr
    except subprocess.TimeoutExpired as e:
        safe_print(f"Time limit reached ({TIMEOUT}s).")
        output = (e.stdout if e.stdout else "") + "\n" + (e.stderr if e.stderr else "")
    except Exception as e:
        safe_print(f"Execution error: {e}")
        return

    lines = output.splitlines()
    ansi_escape = re.compile(r"\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])")

    safe_print("-" * 40)
    safe_print("SCANNING FOR ERRORS...")
    found_lines = 0
    capturing = False

    for raw_line in lines:
        line = ansi_escape.sub("", raw_line).strip()

        is_error_start = (
            "ERROR" in line.upper()
            or "EXCEPTION" in line.upper()
            or (line.startswith("E ") and len(line) > 5 and line[2].isdigit())
            or " <C++ Error>" in line
        )

        if is_error_start:
            capturing = True
            found_lines += 1
            safe_print(raw_line)
            continue

        if capturing:
            if raw_line and (
                raw_line.startswith("   ")
                or raw_line.startswith("\t")
                or raw_line[0].isspace()
            ):
                safe_print(raw_line)
            else:
                capturing = False

    if found_lines == 0:
        safe_print("FILTER REPORT: No lines matched 'ERROR/EXCEPTION/E 0:00'.")
        safe_print("   Checking first 10 lines of raw output for context:")
        for i in range(min(10, len(lines))):
            safe_print(f"   Line {i}: {repr(lines[i])}")
    else:
        safe_print(f"Found {found_lines} error blocks.")

    safe_print("-" * 40)


if __name__ == "__main__":
    main()
