import re

content = 'const ItemDefs = preload("res://modules/world_player_v2/features/inventory/item_definitions.gd")'
old_name = "inventory"
pattern_str = rf"(modules/world_player_v2/features/){re.escape(old_name)}([\\/\"\'\s])"
regex = re.compile(pattern_str)

print(f"Pattern: {pattern_str}")
match = regex.search(content)
if match:
    print(f"Match found: {match.group(0)}")
    print(f"Groups: {match.groups()}")
else:
    print("No match found.")

# Test file reading
try:
    with open(r"modules/world_player_v2/features/player_modes/mode_manager.gd", "r", encoding="utf-8") as f:
        file_content = f.read()
        print(f"File read success. Length: {len(file_content)}")
        match_file = regex.search(file_content)
        if match_file:
            print("Match found in file content!")
        else:
            print("No match in file content.")
except Exception as e:
    print(f"File read error: {e}")
