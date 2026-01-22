#!/usr/bin/env python3
"""
Search and replace script to migrate from DebugSettings to DebugManager.
Replaces all instances of 'DebugSettings.' with 'DebugManager.' in .gd files.
"""

import os
import re
from pathlib import Path

# Configuration
PROJECT_ROOT = r"c:\Users\Windows10_new\Documents\gpu-marching-cubes"
SEARCH_PATTERN = r"DebugSettings\."
REPLACE_WITH = "DebugManager."
FILE_EXTENSION = ".gd"
EXCLUDE_DIRS = {".godot", ".git", "__pycache__", ".gemini"}

def find_gd_files(root_dir):
    """Recursively find all .gd files, excluding certain directories."""
    gd_files = []
    for root, dirs, files in os.walk(root_dir):
        # Remove excluded directories from search
        dirs[:] = [d for d in dirs if d not in EXCLUDE_DIRS]
        
        for file in files:
            if file.endswith(FILE_EXTENSION):
                gd_files.append(Path(root) / file)
    
    return gd_files

def replace_in_file(file_path):
    """Replace all instances of search pattern in a single file."""
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            content = f.read()
        
        # Count replacements
        original_content = content
        new_content = re.sub(SEARCH_PATTERN, REPLACE_WITH, content)
        
        # Only write if changes were made
        if new_content != original_content:
            replacements = len(re.findall(SEARCH_PATTERN, original_content))
            with open(file_path, 'w', encoding='utf-8') as f:
                f.write(new_content)
            return replacements
        
        return 0
    
    except Exception as e:
        print(f"❌ Error processing {file_path}: {e}")
        return 0

def main():
    print(f"🔍 Searching for .gd files in: {PROJECT_ROOT}")
    print(f"   Excluding directories: {', '.join(EXCLUDE_DIRS)}")
    print(f"   Pattern: '{SEARCH_PATTERN}' → '{REPLACE_WITH}'")
    print()
    
    # Find all .gd files
    gd_files = find_gd_files(PROJECT_ROOT)
    print(f"📁 Found {len(gd_files)} .gd files\n")
    
    # Process each file
    total_replacements = 0
    files_modified = 0
    
    for file_path in gd_files:
        replacements = replace_in_file(file_path)
        if replacements > 0:
            files_modified += 1
            total_replacements += replacements
            relative_path = file_path.relative_to(PROJECT_ROOT)
            print(f"✅ {relative_path}: {replacements} replacements")
    
    print()
    print("=" * 60)
    print(f"✨ Migration Complete!")
    print(f"   Files modified: {files_modified}")
    print(f"   Total replacements: {total_replacements}")
    print("=" * 60)

if __name__ == "__main__":
    main()
