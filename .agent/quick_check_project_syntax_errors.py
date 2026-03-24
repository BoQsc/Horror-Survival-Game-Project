import subprocess
import sys
import time

# Configuration
GODOT_BIN = r"C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe"
PROJECT_PATH = r"C:\Users\Windows10_new\Documents\gpu-marching-cubes"
TIMEOUT = 3  # Seconds to run


def safe_print(text: str = "", end: str = "\n") -> None:
    sys.stdout.write(text.encode(sys.stdout.encoding or "utf-8", errors="replace").decode(sys.stdout.encoding or "utf-8"))
    sys.stdout.write(end)


def main():
    safe_print(f"Running Godot for {TIMEOUT}s...")
    safe_print("-" * 50)

    cmd = [
        GODOT_BIN,
        "--path",
        PROJECT_PATH,
        "--debug",
    ]

    try:
        process = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
            bufsize=1,
        )

        start_time = time.time()

        while True:
            if time.time() - start_time > TIMEOUT:
                safe_print(f"\nTime limit reached ({TIMEOUT}s). Terminating...")
                process.terminate()
                break

            output = process.stdout.readline()
            if output == "" and process.poll() is not None:
                break

            if output:
                safe_print(output, end="")
                sys.stdout.flush()

        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()

    except Exception as e:
        safe_print(f"Execution error: {e}")


if __name__ == "__main__":
    main()
