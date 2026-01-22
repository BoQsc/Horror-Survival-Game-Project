
input_file = r'c:\Users\Windows10_new\Documents\gpu-marching-cubes\modules\tools\sketchfab_scene2.tscn'

with open(input_file, 'r', encoding='utf-8') as f:
    lines = f.readlines()

output_lines = []

for line in lines:
    stripped = line.strip()
    
    # Change joint_type = 1 (Pin) to 2 (Cone) for better default stability
    # Or 5 (6DOF)
    if stripped == 'joint_type = 1':
        # Don't change Bip01 Pelvis_04 if it was set to 0 (root)
        # But wait, my previous script changed valid lines in place.
        # This simple check replaces ALL type 1.
        # Assuming Pelvis is type 0 now from previous step, it won't be matched.
        output_lines.append('joint_type = 2\n')
    else:
        output_lines.append(line)

with open(input_file, 'w', encoding='utf-8') as f:
    f.writelines(output_lines)

print("Converted Pin Constraints to ConeConstraints.")
