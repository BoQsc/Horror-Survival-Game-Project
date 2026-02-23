---
name: windows-python-dev
description: Strictly enforces the use of the Python interpreter for all system operations, file manipulations, and command executions on Windows. Use this whenever interacting with the Windows OS, managing files, or running build tasks to entirely avoid cmd.exe and PowerShell.
---

# Windows Python-Only Development Skill

You are operating in a Windows environment where the use of `cmd.exe` and `powershell.exe` is strictly forbidden. You must perform all file system operations, OS interactions, and script executions exclusively through the Python interpreter.

## Core Directives

1. **NO SHELLS:** Never generate or execute `powershell`, `pwsh`, `cmd`, or `.bat` commands.
2. **PYTHON ONLY:** To achieve any OS-level task, you must write and execute Python code. You can do this by passing inline commands via `python -c "..."` or by creating a temporary `.py` script and running it.
3. **USE THE STANDARD LIBRARY:** Leverage Python's built-in modules (`os`, `sys`, `shutil`, `pathlib`, `subprocess`, `glob`) to replace standard terminal commands.

## Common Task Translations

When you need to perform standard terminal actions, use their Python equivalents:

* **List directories (dir/ls):** `python -c "import os; print('\n'.join(os.listdir('.')))"`
* **Create directory (mkdir):** `python -c "import os; os.makedirs('path/to/dir', exist_ok=True)"`
* **Move/Rename (move/mv):** `python -c "import shutil; shutil.move('source', 'dest')"`
* **Delete file (del/rm):** `python -c "import os; os.remove('file.txt')"`
* **Delete directory tree (rmdir /s /q):** `python -c "import shutil; shutil.rmtree('dir_path')"`
* **Read file (type/cat):** `python -c "print(open('file.txt').read())"`

## Handling External Tools (Executables)

If you must run an external tool (e.g., `git`, `docker`, or a compiler), you must wrap it in Python's `subprocess` module rather than calling it directly in a shell:

    # Instead of running `git status` in the shell, use:
    python -c "import subprocess; subprocess.run(['git', 'status'])"

## How to use it

1. Assess the user's request.
2. Formulate the OS-level actions required to fulfill it.
3. Write the necessary Python code to achieve those actions.
4. Execute the Python code. If the code is complex, write it to a `temp_action.py` file, execute `python temp_action.py`, and then optionally delete the temp file using Python.
