import json
import os
import subprocess

class PrefabBuilder:
    def __init__(self, name, x_size, y_size, z_size, grade_y=0):
        self.name = name
        self.size = [x_size, y_size, z_size]
        self.grade_y = grade_y
        
        # Initialize grid with empty air
        self.grid = [[["." for x in range(x_size)] for z in range(z_size)] for y in range(y_size)]
        self.objects = []
        
    def fill_box(self, x, y, z, w, h, d, token="[1]"):
        for iy in range(y, y+h):
            for iz in range(z, z+d):
                for ix in range(x, x+w):
                    if self._in_bounds(ix, iy, iz):
                        self.grid[iy][iz][ix] = token
                        
    def carve_box(self, x, y, z, w, h, d):
        self.fill_box(x, y, z, w, h, d, ".")
        
    def add_object(self, obj_id, x, y, z, rot=0, frac_y=0.0):
        self.objects.append([obj_id, float(x), float(y), float(z), rot, frac_y])
        
    def add_stairs_up(self, x, y, z, facing_z=True, direction=0):
        # direction: 0 = face +Z, 1 = face +X, 2 = face -Z, 3 = face -X
        token = f"[4:{direction}]" if direction != 0 else "[4]"
        
        if self._in_bounds(x, y, z):
            self.grid[y][z][x] = token
            
            # 1. Provide Headroom (clear space above stairs)
            if self._in_bounds(x, y+1, z):
                self.grid[y+1][z][x] = "."
            if self._in_bounds(x, y+2, z):
                self.grid[y+2][z][x] = "." # 2 blocks of air for safety
            
            # 2. Add Top Landing (must be solid with air above)
            dx, dz = 0, 0
            if direction == 0: dz = 1
            elif direction == 1: dx = 1
            elif direction == 2: dz = -1
            elif direction == 3: dx = -1
            
            landing_x, landing_y, landing_z = x + dx, y + 1, z + dz
            # Clear space for the player to step into
            if self._in_bounds(landing_x, landing_y, landing_z):
                self.grid[landing_y][landing_z][landing_x] = "."
            if self._in_bounds(landing_x, landing_y + 1, landing_z):
                self.grid[landing_y + 1][landing_z][landing_x] = "."
            # Solid block under their feet at landing
            if self._in_bounds(landing_x, landing_y - 1, landing_z):
                if self.grid[landing_y - 1][landing_z][landing_x] not in ["[4]", "[4:0]", "[4:1]", "[4:2]", "[4:3]"]:
                    self.grid[landing_y - 1][landing_z][landing_x] = "[1]"

            # 3. Add Bottom Approach (must be clear space at stair foot level)
            approach_x, approach_y, approach_z = x - dx, y, z - dz
            if self._in_bounds(approach_x, approach_y, approach_z):
                 self.grid[approach_y][approach_z][approach_x] = "."
            if self._in_bounds(approach_x, approach_y + 1, approach_z):
                 self.grid[approach_y + 1][approach_z][approach_x] = "."

    def _in_bounds(self, x, y, z):
        return 0 <= x < self.size[0] and 0 <= y < self.size[1] and 0 <= z < self.size[2]
        
    def get_surface_footprint(self):
        min_x, max_x = self.size[0], 0
        min_z, max_z = self.size[2], 0
        found = False
        
        y = self.grade_y
        if y < self.size[1]:
            for z in range(self.size[2]):
                for x in range(self.size[0]):
                    if self.grid[y][z][x] != ".":
                        min_x = min(min_x, x)
                        max_x = max(max_x, x)
                        min_z = min(min_z, z)
                        max_z = max(max_z, z)
                        found = True
        
        if not found:
            return {"min": [0,0], "max": [self.size[0]-1, self.size[2]-1]}
            
        return {"min": [min_x, min_z], "max": [max_x, max_z]}

    def get_excavation_volumes(self):
        # We find empty spaces BELOW grade_y that are enclosed by solids (rough estimation)
        # We'll just define the whole basement as one big excavation box based on where [1] starts and ends
        # For a more exact way, we'd do a flood-fill 3D algorithm. For now, let bounding box of the basement work:
        min_x, max_x = self.size[0], 0
        min_y, max_y = self.size[1], 0
        min_z, max_z = self.size[2], 0
        found = False
        
        for y in range(0, self.grade_y + 1):  # Include grade_y for stairs breaking through
            for z in range(self.size[2]):
                for x in range(self.size[0]):
                    if self.grid[y][z][x] == ".":
                        # Is it inside walls?
                        # Check if there is a wall at some point to the left/right/forward/back
                        has_wall_x = any(self.grid[y][z][ix] != "." for ix in range(x)) and any(self.grid[y][z][ix] != "." for ix in range(x+1, self.size[0]))
                        has_wall_z = any(self.grid[y][iz][x] != "." for iz in range(z)) and any(self.grid[y][iz][x] != "." for iz in range(z+1, self.size[2]))
                        if has_wall_x and has_wall_z:
                            min_x = min(min_x, x)
                            max_x = max(max_x, x)
                            min_y = min(min_y, y)
                            max_y = max(max_y, y)
                            min_z = min(min_z, z)
                            max_z = max(max_z, z)
                            found = True
                            
        # Include stairs at grade_y in excavation bounds
        for y in range(0, self.grade_y + 1):
             for z in range(self.size[2]):
                for x in range(self.size[0]):
                    if "[4]" in self.grid[y][z][x]:
                        min_x = min(min_x, x)
                        max_x = max(max_x, x)
                        min_y = min(min_y, y)
                        max_y = max(max_y, y)
                        min_z = min(min_z, z)
                        max_z = max(max_z, z)
                        found = True
                            
        if not found:
            return []
            
        return [{
            "min": [min_x, min_y, min_z],
            "max": [max_x, max_y, max_z]
        }]

    def export(self, filepath):
        layers_out = []
        for y in range(self.size[1]):
            for z in range(self.size[2]):
                row = " ".join(self.grid[y][z])
                layers_out.append(row)
            if y < self.size[1] - 1:
                layers_out.append("---")
                
        placement = {
            "grade_y": self.grade_y,
            "auto_carve_volume": self.grade_y > 0,
            "seal_foundation": True,
            "max_foundation_gap": 4.0,
            "surface_footprint": self.get_surface_footprint(),
            "reservation_footprint": {"min": [0,0], "max": [self.size[0]-1, self.size[2]-1]},
            "excavation_volumes": self.get_excavation_volumes()
        }
        
        data = {
            "name": self.name,
            "version": 2,
            "size": self.size,
            "layers": layers_out,
            "placement": placement,
            "objects": self.objects
        }
        
        with open(filepath, 'w') as f:
            json.dump(data, f, indent='\t')
        
        # Run Godot headless validation
        print(f"Saved {self.name}. Running Godot Headless Validator...")
        godot_exe = r"C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe"
        
        val_script = """extends SceneTree
func _init():
    var PrefabGeometry = load('res://world_building_system/prefab_geometry.gd')
    var validation = PrefabGeometry.get_prefab_validation('{name}')
    var f = FileAccess.open('res://validation_output.txt', FileAccess.WRITE)
    f.store_string(JSON.stringify(validation, '  '))
    f.close()
    quit()
"""
        val_script = val_script.replace('{name}', self.name)
        with open('scripts/tmp_val.gd', 'w') as f:
            f.write(val_script)
            
        subprocess.run([godot_exe, '--headless', '-s', 'scripts/tmp_val.gd'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        
        try:
            with open('validation_output.txt', 'r') as f:
                val = json.load(f)
            print(f"Validation Result for '{self.name}':")
            print(f"  Valid: {val.get('valid_for_spawn', False)}")
            if val.get('errors'):
                print(f"  Errors: {val['errors']}")
            if val.get('warnings'):
                print(f"  Warnings: {val['warnings']}")
        except Exception as e:
            print("Could not read Godot validation output...", e)

if __name__ == '__main__':
    # Very small test
    b = PrefabBuilder("test_builder", 5, 5, 5, grade_y=2)
    b.fill_box(0, 0, 0, 5, 3, 5, "[1]")
    b.carve_box(1, 1, 1, 3, 2, 3) 
    b.add_stairs_up(2, 1, 3, direction=2) # face -Z (wait, direction usually 0=+Z, 1=+X, 2=-Z, 3=-X)
    b.export("world_prefabs/test_builder.json")
