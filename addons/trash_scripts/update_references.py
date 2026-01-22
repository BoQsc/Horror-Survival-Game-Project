import os
import re
import time

# Configuration
PROJECT_ROOT = r"c:\Users\Windows10_new\Documents\gpu-marching-cubes"
FEATURES_DIR = r"modules/world_player_v2/features"
PREFIX = "player_"
ALLOWED_EXTENSIONS = {'.gd', '.tscn', '.tres', '.md', '.txt', '.json', '.yaml', '.yml', '.org'}

def get_renamed_map(root_dir, features_rel_path, prefix):
    features_abs_path = os.path.join(root_dir, features_rel_path)
    mapping = {}
    
    if not os.path.exists(features_abs_path):
        print(f"Error: Features directory not found at {features_abs_path}")
        return mapping

    print(f"Scanning {features_abs_path} for folders starting with '{prefix}'...")
    for item in os.listdir(features_abs_path):
        if item.startswith(prefix) and os.path.isdir(os.path.join(features_abs_path, item)):
            old_name = item[len(prefix):] 
            mapping[old_name] = item
            # print(f"  Mapped: {old_name} -> {item}")
    return mapping

def update_files(root_dir, mapping):
    count = 0
    files_modified = 0
    files_scanned = 0
    
    patterns = []
    for old_name, new_name in mapping.items():
        regex = re.compile(rf"(modules/world_player_v2/features/){re.escape(old_name)}([\\/\"\'\s])")
        patterns.append((regex, new_name))

    print(f"Scanning files in {root_dir}...")
    start_time = time.time()
    
    for dirpath, dirnames, filenames in os.walk(root_dir):
        # Filter directories to avoid recursion loops or massive hidden dirs
        dirnames[:] = [d for d in dirnames if d not in {'.git', '.godot', '.import', '__pycache__'}]
        
        for filename in filenames:
            ext = os.path.splitext(filename)[1].lower()
            if ext not in ALLOWED_EXTENSIONS:
                continue

            if filename == "update_references.py":
                continue

            file_path = os.path.join(dirpath, filename)
            files_scanned += 1
            
            if files_scanned % 1000 == 0:
                print(f"Scanned {files_scanned} files...")

            try:
                # Read file content
                with open(file_path, "r", encoding="utf-8") as f:
                    content = f.read()
                
                new_content = content
                file_changed = False
                
                # Apply replacements
                for regex, new_name in patterns:
                    def replace_func(match):
                        return f"{match.group(1)}{new_name}{match.group(2)}"
                    
                    if regex.search(new_content):
                        new_content_after = regex.sub(replace_func, new_content)
                        if new_content_after != new_content:
                            new_content = new_content_after
                            file_changed = True
                            count += 1
                
                if file_changed:
                    print(f"Modifying: {file_path}")
                    with open(file_path, "w", encoding="utf-8") as f:
                        f.write(new_content)
                    files_modified += 1
                    
            except UnicodeDecodeError:
                # Skip files that aren't valid utf-8 text
                continue
            except Exception as e:
                print(f"Error processing {file_path}: {e}")

    end_time = time.time()
    print(f"\nSummary: Scanned {files_scanned} files in {end_time - start_time:.2f}s.")
    print(f"Modified {files_modified} files with {count} replacements.")

def main():
    mapping = get_renamed_map(PROJECT_ROOT, FEATURES_DIR, PREFIX)
    if not mapping:
        print("No mapping found.")
        return

    print("\nStarting update...")
    update_files(PROJECT_ROOT, mapping)

if __name__ == "__main__":
    main()
