import json

def check_file():
    with open('c:/Users/Windows10_new/Documents/gpu-marching-cubes/world_prefabs/new_wooden_house_2floor_secret_facility.json', 'r') as f:
        data = json.load(f)
        
    for i, obj in enumerate(data['objects']):
        print(f"obj {i}: {obj}")

    print("size:", data["size"])

    layers = data["layers"]
    current_layer = 0
    y_lines = 0
    for l in layers:
        if l == "---":
            print(f"layer {current_layer} has {y_lines} rows")
            current_layer += 1
            y_lines = 0
        else:
            parts = l.strip().split()
            if len(parts) != data["size"][0]:
                print(f"ERROR layer {current_layer} row {y_lines} has {len(parts)} parts instead of {data['size'][0]}")
            y_lines += 1
    print(f"layer {current_layer} has {y_lines} rows")

check_file()
