#!/usr/bin/env python3
"""
Updates file references from old path to new path
Usage: python update_door_references.py
"""

import os
import re
from pathlib import Path

# Configuration
OLD_PATH = "res://models/interactive_door/"
NEW_PATH = "res://models/objects/interactive_door/"
PROJECT_ROOT = Path(__file__).parent
EXTENSIONS = ['.gd', '.tscn', '.tres', '.godot', '.import', '.txt', '.md']

def update_references():
    """Search and replace path references in all project files"""
    files_changed = []
    total_replacements = 0
    
    print(f"Searching for references to: {OLD_PATH}")
    print(f"Replacing with: {NEW_PATH}\n")
    
    # Walk through all files in project
    for root, dirs, files in os.walk(PROJECT_ROOT):
        # Skip hidden directories and common ignore patterns
        dirs[:] = [d for d in dirs if not d.startswith('.') and d not in ['__pycache__', 'bin', 'build']]
        
        for filename in files:
            file_path = Path(root) / filename
            
            # Check if file extension is in our list
            if file_path.suffix not in EXTENSIONS:
                continue
            
            try:
                # Read file content
                with open(file_path, 'r', encoding='utf-8') as f:
                    content = f.read()
                
                # Check if old path exists in file
                if OLD_PATH not in content:
                    continue
                
                # Count occurrences
                count = content.count(OLD_PATH)
                
                # Replace old path with new path
                new_content = content.replace(OLD_PATH, NEW_PATH)
                
                # Write back to file
                with open(file_path, 'w', encoding='utf-8') as f:
                    f.write(new_content)
                
                # Track changes
                relative_path = file_path.relative_to(PROJECT_ROOT)
                files_changed.append((relative_path, count))
                total_replacements += count
                
                print(f"✓ Updated {relative_path} ({count} replacement{'s' if count > 1 else ''})")
                
            except Exception as e:
                print(f"✗ Error processing {file_path}: {e}")
    
    # Summary
    print(f"\n{'='*60}")
    print(f"Summary:")
    print(f"  Files changed: {len(files_changed)}")
    print(f"  Total replacements: {total_replacements}")
    print(f"{'='*60}")
    
    if not files_changed:
        print("\nNo references found. The path may have already been updated.")
    
    return files_changed

if __name__ == "__main__":
    print("Door Reference Updater")
    print("="*60)
    update_references()
    print("\nDone!")
