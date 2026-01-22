"""
Fast scan for references to the moved 'entities' folder.
Focus on key file types only: .gd, .tscn, .tres, .gdextension
"""
import os
import re
from pathlib import Path

# Configuration
PROJECT_ROOT = Path(__file__).parent
OLD_PATH_PATTERNS = [
    r'res://entities',
    r'"entities/',
    r"'entities/",
    r'entities\\',
]

# Only scan critical file types
SCAN_EXTENSIONS = ['.gd', '.tscn', '.tres', '.gdextension', '.cfg']

# Directories to skip
SKIP_DIRS = {
    '.git', '.godot', '.import', '__pycache__', 
    'build', 'bin', '.vs', 'node_modules', 'addons'
}

def scan_file(filepath):
    """Scan a single file for references to entities folder."""
    results = []
    try:
        with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
            content = f.read()
            
        # Quick check first
        if 'entities' not in content.lower():
            return results
            
        lines = content.split('\n')
        for line_num, line in enumerate(lines, 1):
            # Check for any old path pattern
            for pattern in OLD_PATH_PATTERNS:
                if re.search(pattern, line, re.IGNORECASE):
                    results.append({
                        'file': str(filepath.relative_to(PROJECT_ROOT)),
                        'line': line_num,
                        'content': line.strip(),
                    })
                    break  # Only report once per line
    except Exception as e:
        pass  # Skip files that can't be read
    
    return results

def scan_project():
    """Fast scan of project for entities references."""
    print("[FAST_SCAN] Starting targeted scan for 'entities' folder references...")
    print(f"[FAST_SCAN] Old path: entities/")
    print(f"[FAST_SCAN] New path: game/entities/")
    print(f"[FAST_SCAN] Scanning: {', '.join(SCAN_EXTENSIONS)}")
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
                
                # Show progress every 50 files
                if file_count % 50 == 0:
                    print(f"[FAST_SCAN] Scanned {file_count} files...", end='\r')
                
                results = scan_file(filepath)
                all_results.extend(results)
    
    print(f"\n[FAST_SCAN] Scanned {file_count} files")
    print(f"[FAST_SCAN] Found {len(all_results)} references")
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
            for ref in refs:
                preview = ref['content'][:80]
                print(f"   L{ref['line']:4d}: {preview}")
        
        print()
        print("=" * 80)
        print(f"SUMMARY: {len(by_file)} files need updates")
        print("=" * 80)
        
        # Print file list for easy reference
        print("\nFiles to update:")
        for filepath in sorted(by_file.keys()):
            print(f"  - {filepath}")
    else:
        print("✅ No references to old 'entities' path found!")
    
    return all_results

if __name__ == "__main__":
    results = scan_project()
    print(f"\n[FAST_SCAN] Complete. Total references: {len(results)}")
