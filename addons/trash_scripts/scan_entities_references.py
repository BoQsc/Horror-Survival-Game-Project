"""
Scan project for references to the moved 'entities' folder.
The folder was moved from root to game/entities.
"""
import os
import re
from pathlib import Path

# Configuration
PROJECT_ROOT = Path(__file__).parent
OLD_PATH_PATTERNS = [
    r'entities/',
    r'entities\\',
    r'"entities',
    r"'entities",
    r'res://entities',
    r'/entities/',
]

# File extensions to scan
SCAN_EXTENSIONS = [
    '.gd', '.gdshader', '.tscn', '.tres', '.gdextension', 
    '.cfg', '.import', '.md', '.txt', '.json', '.glsl',
    '.py', '.cpp', '.h', '.hpp'
]

# Directories to skip
SKIP_DIRS = {
    '.git', '.godot', '.import', '__pycache__', 
    'build', 'bin', '.vs', 'node_modules'
}

def scan_file(filepath):
    """Scan a single file for references to entities folder."""
    results = []
    try:
        with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
            lines = f.readlines()
            
        for line_num, line in enumerate(lines, 1):
            # Check for any old path pattern
            for pattern in OLD_PATH_PATTERNS:
                if re.search(pattern, line, re.IGNORECASE):
                    results.append({
                        'file': str(filepath.relative_to(PROJECT_ROOT)),
                        'line': line_num,
                        'content': line.strip(),
                        'pattern': pattern
                    })
                    break  # Only report once per line
    except Exception as e:
        print(f"[SCAN_ERROR] Failed to read {filepath}: {e}")
    
    return results

def scan_project():
    """Scan entire project for entities references."""
    print("[SCAN] Starting project scan for 'entities' folder references...")
    print(f"[SCAN] Project root: {PROJECT_ROOT}")
    print(f"[SCAN] Old path: entities/")
    print(f"[SCAN] New path: game/entities/")
    print()
    
    all_results = []
    file_count = 0
    
    for root, dirs, files in os.walk(PROJECT_ROOT):
        # Skip unwanted directories
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        
        for filename in files:
            # Check if file extension should be scanned
            if any(filename.endswith(ext) for ext in SCAN_EXTENSIONS):
                filepath = Path(root) / filename
                file_count += 1
                
                results = scan_file(filepath)
                all_results.extend(results)
    
    print(f"[SCAN] Scanned {file_count} files")
    print(f"[SCAN] Found {len(all_results)} references to 'entities' folder")
    print()
    
    if all_results:
        print("=" * 80)
        print("REFERENCES FOUND - NEED TO UPDATE:")
        print("=" * 80)
        
        # Group by file
        by_file = {}
        for result in all_results:
            if result['file'] not in by_file:
                by_file[result['file']] = []
            by_file[result['file']].append(result)
        
        # Print results grouped by file
        for filepath, refs in sorted(by_file.items()):
            print(f"\n📁 {filepath}")
            print(f"   {len(refs)} reference(s) found:")
            for ref in refs:
                print(f"   Line {ref['line']:4d}: {ref['content'][:100]}")
        
        print()
        print("=" * 80)
        print(f"SUMMARY: {len(by_file)} files need updates")
        print("=" * 80)
        
        # Print file list for easy batch editing
        print("\nFiles to update:")
        for filepath in sorted(by_file.keys()):
            print(f"  - {filepath}")
    else:
        print("✅ No references to old 'entities' path found!")
    
    return all_results

if __name__ == "__main__":
    results = scan_project()
    print(f"\n[SCAN] Scan complete. Total references: {len(results)}")
