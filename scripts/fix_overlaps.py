import json

def fix_overlaps():
    with open('world_prefabs/new_wooden_house_2floor_secret_facility.json', 'r') as f:
        data = json.load(f)
        
    layers = []
    layer_widths = []
    curr_lines = []
    for l in data['layers']:
        if l == '---':
            layers.append(curr_lines)
            curr_lines = []
        else:
            p = l.split()
            layer_widths.append(len(p))
            curr_lines.append(l)
    layers.append(curr_lines)

    valid_objs = []
    for obj in data["objects"]:
        obj_type = obj[0]
        if obj_type in (4, 5):  # Door, Window allowed to overlap
            valid_objs.append(obj)
            continue
        
        # obj is [type, x, y, z, rot, frac_y]
        # x is 1, y is 2, z is 3
        ox = int(obj[1])
        oy = int(obj[2])
        oz = int(obj[3])
        
        # check if it overlaps a 1 block
        if " [1]" in layers[oy][oz] or "[1]" in layers[oy][oz]:
            # wait, I need exact cell check!
            tokens = layers[oy][oz].split()
            if ox < len(tokens):
                token = tokens[ox]
                # Is it filled?
                if token != "." and token != "":
                    print(f"Removed overlapping object {obj} at {ox},{oy},{oz} (found {token})")
                    continue  # skip this object
            
        valid_objs.append(obj)
        
    data["objects"] = valid_objs
    
    with open('world_prefabs/new_wooden_house_2floor_secret_facility.json', 'w') as f:
        json.dump(data, f, indent='\t')

fix_overlaps()
