import subprocess
import os

def toggle_git_final_boss(target_dir=".godot"):
    # 1. Ask Git what the folder is ACTUALLY named in its index
    # We use 'git ls-files' to get the real case-sensitive paths
    try:
        # We search for the directory regardless of case
        files_raw = subprocess.check_output(
            ["git", "ls-files", "-z", "--", f"*{target_dir}*"], 
        ).split(b'\0')
        files = [f for f in files_raw if f and target_dir.lower() in f.decode().lower()]
    except subprocess.CalledProcessError:
        print("Error: Git couldn't find the index.")
        return

    if not files:
        # If Git doesn't see them, we force add them
        print(f"Git index empty for {target_dir}. Force adding...")
        subprocess.run(["git", "add", "-f", target_dir])
        # Re-fetch after adding
        files_raw = subprocess.check_output(["git", "ls-files", "-z", target_dir]).split(b'\0')
        files = [f for f in files_raw if f]

    # 2. Check the flag of the first file (using Git's own path)
    status_info = subprocess.check_output(["git", "ls-files", "-v", files[0]], text=True)
    
    # 'S' or 's' = skip-worktree, 'H' or 'h' = cached
    is_already_skipped = status_info.lower().startswith('s')
    
    action = "--no-skip-worktree" if is_already_skipped else "--skip-worktree"
    status_label = "TRACKED" if is_already_skipped else "HIDDEN (Skip-Worktree)"

    print(f"Applying {action} to {len(files)} files found in Git index...")
    
    # 3. Apply via stdin
    process = subprocess.Popen(
        ["git", "update-index", action, "-z", "--stdin"],
        stdin=subprocess.PIPE
    )
    process.communicate(input=b'\0'.join(files))

    # 4. CRITICAL: Clear the staging area so they don't show as 'new files'
    subprocess.run(["git", "reset", "--", target_dir], capture_output=True)

    print(f"Done! All files in {target_dir} are now {status_label}.")

if __name__ == "__main__":
    toggle_git_final_boss()