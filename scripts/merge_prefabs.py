import json

def main():
    with open('c:/Users/Windows10_new/Documents/gpu-marching-cubes/world_prefabs/unused/new_wooden_house_2floor.json', 'r') as f:
        house = json.load(f)
        
    with open('c:/Users/Windows10_new/Documents/gpu-marching-cubes/world_prefabs/new_wooden_house_secret_facility.json', 'r') as f:
        facility = json.load(f)

    # We want a 12 width X, 16 height Y, 12 depth Z
    combined_size = [12, 16, 12]
    combined_layers = []
    
    flat_layers = []
    
    # facility 0..6
    layer_chunks = []
    current_chunk = []
    for line in facility["layers"]:
        if line == "---":
            layer_chunks.append(current_chunk)
            current_chunk = []
        else:
            current_chunk.append(line)
    layer_chunks.append(current_chunk)
    
    house_chunks = []
    current_chunk = []
    for line in house["layers"]:
        if line == "---":
            house_chunks.append(current_chunk)
            current_chunk = []
        else:
            current_chunk.append(line)
    house_chunks.append(current_chunk)

    for i in range(7):
        flat_layers.extend(layer_chunks[i])
        flat_layers.append("---")
        
    for i in range(9):
        new_layer = []
        for line in house_chunks[i]:
            parts = line.strip().split()
            # pad to 12. current is 10. Add one dot to left, one dot to right.
            # but wait! string line in json might include spaces.
            # so '. ' + line + ' .' is easiest to keep exactly 12 columns
            new_line = ". " + line + " ."
            # Wait! Let's make sure `line` actually has 10 columns by checking parts length.
            # `line` could just be ". . . . ."
            new_layer.append(new_line)
            
        flat_layers.extend(new_layer)
        if i < 8:
            flat_layers.append("---")

    # Add stairs going down at house level 0 (layer 7) and level 1 (layer 8).
    # facility stairs are at layer 6, Z=6, X=6,7. Wait, let's verify where facility stairs end up.
    # In facility, layer 6:
    # Z=6: ". . . [1] [1] [1] [4] [4] [1] . . ."
    # So X=6 and 7 have stairs [4].
    # In layer 7 of facility (which is replaced by house), there was a hole or stairs?
    # No, layer 7 in our new combined will be house layer 0. 
    # house layer 0 is mostly foundation:
    # ". [1] [1] [1] [1] [1] [1] [1] [1] ."
    # Shifted by +1 X, this becomes:
    # Z=6: ". . [1] [1] [1] [1] [1] [1] [1] [1] . ."
    # So X=6 and 7 are [1] (solid). 
    # Let's carve out the floor at Z=6, X=6,7 in house layer 0 (combined layer 7).
    # Actually, the stairs in layer 6 go down into Z=6?
    # Wait, facility stairs go down. Where do they point? 
    # We should carve out exactly enough space. Let's make Z=6, X=6,7 be floor '.' or '[4]' in layer 7?
    # Better to just set them to '.' in both layer 7 and layer 8 so the player can walk down.
    # And maybe make layer 7 have stairs [4:x]? Wait, if layer 6 has stairs, the player steps on those.
    # Let's replace [1] with . at Z=6, X=6,7 for layer 7 and 8.
    
    # Wait, Z=6, X=6 in layer 7:
    # flat_layers for layer 7 is index 7 * (12+1) = 91 offset.
    
    # Layer 7:
    def carve_hole(layer_idx, z, x_range):
        idx_start = layer_idx * 13
        line = flat_layers[idx_start + z]
        parts = line.split()
        for x in x_range:
            parts[x] = "."
        flat_layers[idx_start + z] = " ".join(parts)
        
    carve_hole(7, 8, [6, 7])
    carve_hole(8, 8, [6, 7])

    combined_objects = []
    # add facility objects that are below Y < 7
    for obj in facility["objects"]:
        if obj[2] < 7: # Y is index 2
            combined_objects.append(obj)
            
    # add house objects, shifted Y + 7, X + 1
    for obj in house["objects"]:
        new_obj = list(obj)
        new_obj[2] += 7.0 # Y
        new_obj[1] += 1.0 # X
        combined_objects.append(new_obj)
        
    combined = {
        "name": "new_wooden_house_2floor_secret_facility",
        "version": 2,
        "size": combined_size,
        "layers": flat_layers,
        "placement": facility["placement"],
        "objects": combined_objects
    }
    
    with open('c:/Users/Windows10_new/Documents/gpu-marching-cubes/world_prefabs/new_wooden_house_2floor_secret_facility.json', 'w') as f:
        json.dump(combined, f, indent='\t')

if __name__ == '__main__':
    main()
