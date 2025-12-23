# True 3D World Generation Design

## Vision
Create a **persistent, explorable world** where every voxel has deterministic material based on its 3D position and world seed. Digging at any point reveals what's actually there - not a fake depth-based layer.

## Current Limitations

| Issue | Current Behavior | Desired Behavior |
|-------|------------------|------------------|
| Materials are 2D | Biomes based on XZ only | Full 3D material distribution |
| Depth-based boring | "depth > 3 = stone" everywhere | Varied materials at all depths |
| No cave systems | (Planned but not materialized) | Explorable 3D cave networks |
| Ore = random chance | `ore_noise > 0.75` anywhere | Ore veins you can follow |
| Road material bug | Roads painted underground | Only at surface layer ✅ Fixed |

## Proposed Architecture

### 1. 3D Material Function

Replace depth-based logic with true 3D noise:

```glsl
uint get_material_3d(vec3 world_pos, uint seed) {
    // Layer 1: Surface (Y relative to terrain height - thin layer)
    float surface_dist = world_pos.y - terrain_height_at(world_pos.xz);
    if (surface_dist > -1.0 && surface_dist < 0.5) {
        return get_surface_biome(world_pos.xz);  // Grass/Sand/Snow/Gravel
    }
    
    // Layer 2: Shallow underground (dirt/clay - 1-5 units deep)
    if (surface_dist > -5.0) {
        return get_shallow_material(world_pos);  // Dirt, Clay, Gravel
    }
    
    // Layer 3: Deep underground (3D noise-based)
    return get_deep_material(world_pos);  // Stone types, Ore veins
}
```

### 2. 3D Cave System

Use 3D noise to carve caves (affects density, not materials):

```glsl
float get_cave_density(vec3 world_pos) {
    // Swiss cheese caves using layered 3D noise
    float cave1 = noise3d(world_pos * 0.03);
    float cave2 = noise3d(world_pos * 0.06 + vec3(100.0));
    
    // Caves only form underground (Y < terrain_height - 5)
    float cave_mask = smoothstep(terrain_height - 5.0, terrain_height - 10.0, world_pos.y);
    
    // Combine noise channels
    float cave_factor = (cave1 * 0.5 + cave2 * 0.5);
    if (cave_factor > 0.6 && cave_mask > 0.0) {
        return 1.0;  // Air (carve out)
    }
    return 0.0;  // Keep solid
}
```

### 3. Ore Vein System

Ore veins as 3D worm-like structures:

```glsl
uint get_deep_material(vec3 world_pos) {
    // Check for ore veins using directional 3D noise
    float iron_vein = vein_noise(world_pos * 0.08, 123);  // Seed-based
    float gold_vein = vein_noise(world_pos * 0.05, 456);
    float coal_vein = vein_noise(world_pos * 0.1, 789);
    
    // Y-band restrictions (realistic ore distribution)
    if (world_pos.y < 20.0 && gold_vein > 0.8) return MAT_GOLD;
    if (world_pos.y < 50.0 && iron_vein > 0.75) return MAT_IRON;
    if (coal_vein > 0.7) return MAT_COAL;
    
    // Different stone types at different depths
    float stone_var = noise3d(world_pos * 0.01);
    if (stone_var > 0.3) return MAT_GRANITE;
    return MAT_STONE;
}
```

### 4. Underground Biomes

Special cave biomes using large-scale 3D noise:

```glsl
// Large caves can have biomes: mushroom, crystal, lava
uint get_cave_biome(vec3 world_pos) {
    float biome3d = fbm3d(world_pos * 0.005);
    
    if (biome3d < -0.3 && world_pos.y < 10.0) return CAVE_LAVA;
    if (biome3d > 0.4) return CAVE_CRYSTAL;
    if (biome3d > 0.1) return CAVE_MUSHROOM;
    return CAVE_NORMAL;
}
```

## Material ID Registry (Expanded)

| ID | Material | Notes |
|----|----------|-------|
| 0 | Grass | Surface biome |
| 1 | Stone | Default underground |
| 2 | Ore (generic) | Legacy, replace with specific |
| 3 | Sand | Biome surface |
| 4 | Gravel | Biome surface + underground |
| 5 | Snow | Biome surface |
| 6 | Road | Player/procedural roads |
| 7 | Dirt | Shallow underground |
| 8 | Clay | Shallow underground |
| 9 | Granite | Deep stone variant |
| 10 | Coal | Ore vein |
| 11 | Iron | Ore vein |
| 12 | Gold | Ore vein (deep only) |
| 13 | Crystal | Cave biome decoration |
| 100+ | Player-placed | Building materials |

## Implementation Phases

### Phase 1: Foundation (Current Priority Fix)
- [x] Fix road material underground spillover
- [ ] Add 3D noise function to gen_density.glsl
- [ ] Replace depth-based stone with simple 3D stone variants

### Phase 2: Cave Systems
- [ ] Implement cave carving in density generation
- [ ] Ensure caves don't break surface (mask by terrain height)
- [ ] Add cave floor/ceiling materials

### Phase 3: Ore Veins
- [ ] Implement vein_noise function
- [ ] Add ore types with Y-band distribution
- [ ] Make veins followable (directional noise)

### Phase 4: Underground Biomes
- [ ] Large-scale 3D biome noise
- [ ] Cave-specific materials (crystals, mushrooms)
- [ ] Special lighting zones

### Phase 5: Dynamic Features
- [ ] Water table (underground lakes)
- [ ] Lava pockets
- [ ] Collapsed cave debris

## Key Principles

1. **Deterministic** - Same position + seed = same material always
2. **3D not 2.5D** - Materials vary in all three axes, not just XZ + depth
3. **Persistent** - Digging reveals what's actually there, not calculated on-the-fly fakery
4. **Explorable** - Following an ore vein or cave leads somewhere interesting
5. **Seed-based** - World seed controls all generation for reproducibility

## Files to Modify

| File | Changes |
|------|---------|
| [gen_density.glsl](file:///C:/Users/Windows10_new/Documents/gpu-marching-cubes/marching_cubes/gen_density.glsl) | Core 3D material/cave logic |
| `terrain.gdshader` | Material color mapping for new IDs |
| [chunk_manager.gd](file:///C:/Users/Windows10_new/Documents/gpu-marching-cubes/marching_cubes/chunk_manager.gd) | Ensure material buffers persist correctly |
| [modify_density.glsl](file:///C:/Users/Windows10_new/Documents/gpu-marching-cubes/marching_cubes/modify_density.glsl) | No changes needed (already preserves materials) |

---

> **Note**: This document captures the vision. Implementation should be phased to avoid breaking current functionality.
