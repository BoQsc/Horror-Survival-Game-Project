import sys
from prefab_builder import PrefabBuilder

def build_church():
    # Width 18, Height 16, Depth 26
    b = PrefabBuilder("large_church_with_basement", 18, 16, 26, grade_y=5)
    
    # 1. BASEMENT (Y=1 to Y=5)
    b.fill_box(0, 0, 0, 18, 6, 26, "[1]")  # Solid slab
    b.carve_box(2, 1, 2, 14, 4, 22)        # Hollow interior for basement (Y=1, 2, 3, 4)
    # Give basement some pillars
    for x in [4, 10]:
        for z in [6, 13, 20]:
            b.fill_box(x, 1, z, 2, 4, 2, "[1]")
            
    # 2. MAIN FLOOR (Y=6) is solid above the basement, except where stairs come up
    b.fill_box(1, 5, 1, 16, 1, 24, "[8]") # Floor of church (grade_y=5)
    # The actual walls of the church at Y=6 and up
    b.fill_box(2, 6, 2, 14, 8, 22, "[1]") # Solid block for church exterior
    b.carve_box(3, 6, 3, 12, 7, 20)       # Hollow interior for church (Y=6 to 12)
    b.carve_box(3, 13, 3, 12, 1, 20)      # Attic/Ceiling (Y=13)
    b.fill_box(4, 14, 4, 10, 1, 18, "[1]") # Roof peak

    # 3. STAIRS (Basement to Ground Floor)
    # Basement is Y=1 to Y=4. Ground floor is Y=6 (feet at Y=6, so foundation is Y=5).
    # We need stairs from Y=1 all the way to Y=5.
    stair_x = 13
    stair_z = 21
    # Y=1 -> Y=2
    b.add_stairs_up(stair_x, 1, stair_z, direction=0)
    # Y=2 -> Y=3
    b.add_stairs_up(stair_x, 2, stair_z+1, direction=0)
    # Y=3 -> Y=4
    b.add_stairs_up(stair_x, 3, stair_z+2, direction=0)
    # Y=4 -> Y=5 (Breaks through floor)
    b.add_stairs_up(stair_x, 4, stair_z+3, direction=0)
    # Y=5 -> Y=6 (Reaches grade_y)
    b.add_stairs_up(stair_x, 5, stair_z+4, direction=0)

    # 4. DOOR
    # Front is Z=2. Center X is 8, 9.
    # We carve a hole in the front wall at Y=6, Z=2
    b.carve_box(8, 6, 2, 2, 2, 1)
    b.add_object(4, 8, 6, 2, 0)
    
    # 5. WINDOWS
    # Let's add windows along the sides.
    for z in [6, 10, 14, 18]:
        # Left side
        b.carve_box(2, 7, z, 1, 3, 2)
        b.add_object(5, 2, 7, z, 1)
        # Right side
        b.carve_box(15, 7, z, 1, 3, 2)
        b.add_object(5, 15, 7, z, 3)

    return b

if __name__ == '__main__':
    b = build_church()
    b.export("world_prefabs/large_church_with_basement.json")
