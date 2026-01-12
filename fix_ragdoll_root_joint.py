
input_file = r'c:\Users\Windows10_new\Documents\gpu-marching-cubes\modules\tools\sketchfab_scene2.tscn'

target_node = 'Physical Bone Bip01 Pelvis_04'

with open(input_file, 'r', encoding='utf-8') as f:
    lines = f.readlines()

output_lines = []
in_target_node = False

for line in lines:
    stripped = line.strip()
    
    if stripped.startswith('[node '):
        if f'name="{target_node}"' in stripped:
            in_target_node = True
        else:
            in_target_node = False
    
    if in_target_node and stripped.startswith('joint_type = '):
        # Change joint_type to 0 (None)
        print(f"fixing joint_type for {target_node}")
        output_lines.append('joint_type = 0\n')
    else:
        output_lines.append(line)

with open(input_file, 'w', encoding='utf-8') as f:
    f.writelines(output_lines)

print("Finished fixing root joint.")
