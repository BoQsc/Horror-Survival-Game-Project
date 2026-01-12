
input_file = r'c:\Users\Windows10_new\Documents\gpu-marching-cubes\modules\tools\sketchfab_scene2.tscn'

# Names of nodes to remove
nodes_to_remove = [
    'Physical Bone _rootJoint',
    'Physical Bone Bip01_06'
]

with open(input_file, 'r', encoding='utf-8') as f:
    lines = f.readlines()

output_lines = []
skip_block = False
current_node_name = ""

for line in lines:
    stripped = line.strip()
    
    # Check for start of a new node definition
    if stripped.startswith('[node '):
        skip_block = False # Reset skip flag for the new node
        
        # Parse name
        # Format: [node name="Name" ...]
        parts = stripped.split('name="')
        if len(parts) > 1:
            name_part = parts[1].split('"')[0]
            current_node_name = name_part
            
            if name_part in nodes_to_remove:
                print(f"Removing node: {name_part}")
                skip_block = True
            
            # Also remove the CollisionShape children of these nodes
            # The parent="PATH" usually contains the name of the parent node.
            # We can check if "parent" attribute ends with one of our removed nodes.
            # Example: parent=".../Physical Bone _rootJoint"
            if 'parent="' in stripped:
                parent_path = stripped.split('parent="')[1].split('"')[0]
                for removed_node in nodes_to_remove:
                    if parent_path.endswith(removed_node):
                        print(f"Removing child of {removed_node}: {name_part}")
                        skip_block = True
                        break

    if not skip_block:
        output_lines.append(line)

with open(input_file, 'w', encoding='utf-8') as f:
    f.writelines(output_lines)

print("Finished removing nodes.")
