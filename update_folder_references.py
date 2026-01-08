"""
Update Folder References Script
Replaces old folder paths with new world_ prefixed paths.

Usage:
    python update_folder_references.py          # Dry run (show changes)
    python update_folder_references.py --apply  # Apply changes
"""

import os
import sys

# Configuration
PROJECT_ROOT = os.path.dirname(os.path.abspath(__file__))

REPLACEMENTS = [
    ("res://building_system/", "res://world_building_system/"),
    ("res://greedy_meshing/", "res://world_greedy_meshing/"),
    ("res://marching_cubes/", "res://world_marching_cubes/"),
]

# File extensions to process
EXTENSIONS = {".gd", ".tscn", ".tres", ".gdshader", ".glsl", ".import", ".cfg", ".md"}

# Directories to skip
SKIP_DIRS = {".git", ".godot", "__pycache__", "node_modules"}


def find_files(root_dir):
    """Find all files with matching extensions."""
    for dirpath, dirnames, filenames in os.walk(root_dir):
        # Skip excluded directories
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        
        for filename in filenames:
            ext = os.path.splitext(filename)[1].lower()
            if ext in EXTENSIONS:
                yield os.path.join(dirpath, filename)


def process_file(filepath, dry_run=True):
    """Process a single file and replace paths."""
    try:
        with open(filepath, "r", encoding="utf-8", errors="ignore") as f:
            content = f.read()
    except Exception as e:
        print(f"[ERROR] Cannot read {filepath}: {e}")
        return 0
    
    original = content
    changes = []
    
    for old_path, new_path in REPLACEMENTS:
        count = content.count(old_path)
        if count > 0:
            changes.append(f"  {old_path} -> {new_path} ({count}x)")
            content = content.replace(old_path, new_path)
    
    if content != original:
        rel_path = os.path.relpath(filepath, PROJECT_ROOT)
        print(f"\n[UPDATE_REFS] {rel_path}")
        for change in changes:
            print(change)
        
        if not dry_run:
            try:
                with open(filepath, "w", encoding="utf-8") as f:
                    f.write(content)
                print("  -> Applied!")
            except Exception as e:
                print(f"  -> [ERROR] Cannot write: {e}")
                return 0
        
        return len(changes)
    
    return 0


def main():
    dry_run = "--apply" not in sys.argv
    
    print("=" * 60)
    print("UPDATE FOLDER REFERENCES")
    print("=" * 60)
    print(f"Project root: {PROJECT_ROOT}")
    print(f"Mode: {'DRY RUN (use --apply to make changes)' if dry_run else 'APPLYING CHANGES'}")
    print()
    print("Replacements:")
    for old, new in REPLACEMENTS:
        print(f"  {old} -> {new}")
    print("=" * 60)
    
    total_files = 0
    total_changes = 0
    
    for filepath in find_files(PROJECT_ROOT):
        changes = process_file(filepath, dry_run)
        if changes > 0:
            total_files += 1
            total_changes += changes
    
    print()
    print("=" * 60)
    print(f"SUMMARY: {total_changes} replacements in {total_files} files")
    if dry_run:
        print("Run with --apply to apply these changes")
    else:
        print("Changes applied successfully!")
    print("=" * 60)


if __name__ == "__main__":
    main()
