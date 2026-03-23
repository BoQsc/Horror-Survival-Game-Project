import json
with open('world_prefabs/new_wooden_house_2floor_secret_facility.json', 'r') as f:
    d = json.load(f)

layers = []
c = []
for l in d['layers']:
    if l == '---':
        layers.append(c)
        c = []
    else:
        c.append(l)
layers.append(c)

print("Layer 6:")
for z in range(12):
    if "[4]" in layers[6][z] or "[4:0]" in layers[6][z]:
        print(f"  Z={z}: {layers[6][z]}")
