#[compute]
#version 450

// 33x33x33 grid points to cover a 32x32x32 voxel chunk + 1 neighbor edge
layout(local_size_x = 4, local_size_y = 4, local_size_z = 4) in;

// Output: Density values
layout(set = 0, binding = 0, std430) restrict buffer DensityBuffer {
    float values[];
} density_buffer;

// Output: Material IDs (packed as uint, one per voxel)
layout(set = 0, binding = 1, std430) restrict buffer MaterialBuffer {
    uint values[];
} material_buffer;

layout(push_constant) uniform PushConstants {
    vec4 chunk_offset; // .xyz is position
    float noise_freq;
    float terrain_height;
    float road_spacing;  // Grid spacing for roads (0 = no procedural roads)
    float road_width;    // Width of roads
} params;

// === Noise Functions ===
float hash(vec3 p) {
    p = fract(p * 0.3183099 + .1);
    p *= 17.0;
    return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

float hash2(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float noise(vec3 x) {
    vec3 i = floor(x);
    vec3 f = fract(x);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(mix( hash(i + vec3(0,0,0)), hash(i + vec3(1,0,0)), f.x),
                   mix( hash(i + vec3(0,1,0)), hash(i + vec3(1,1,0)), f.x), f.y),
               mix(mix( hash(i + vec3(0,0,1)), hash(i + vec3(1,0,1)), f.x),
                   mix( hash(i + vec3(0,1,1)), hash(i + vec3(1,1,1)), f.x), f.y), f.z);
}

// === 2D Simplex Noise for Biomes (matching terrain.gdshader) ===
vec2 hash2d(vec2 p) {
    p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
    return -1.0 + 2.0 * fract(sin(p) * 43758.5453123);
}

float noise2d(vec2 p) {
    const float K1 = 0.366025404; // (sqrt(3)-1)/2
    const float K2 = 0.211324865; // (3-sqrt(3))/6

    vec2 i = floor(p + (p.x + p.y) * K1);
    vec2 a = p - i + (i.x + i.y) * K2;
    float m = step(a.y, a.x); 
    vec2 o = vec2(m, 1.0 - m);
    vec2 b = a - o + K2;
    vec2 c = a - 1.0 + 2.0 * K2;

    vec3 h = max(0.5 - vec3(dot(a, a), dot(b, b), dot(c, c)), 0.0);
    vec3 n = h * h * h * h * vec3(dot(a, hash2d(i + 0.0)), dot(b, hash2d(i + o)), dot(c, hash2d(i + 1.0)));

    return dot(n, vec3(70.0));
}

// Fractal Brownian Motion for natural biome shapes (matching terrain.gdshader)
float fbm(vec2 p) {
    float f = 0.0;
    float w = 0.5;
    for (int i = 0; i < 3; i++) {
        f += w * noise2d(p);
        p *= 2.0;
        w *= 0.5;
    }
    return f;
}

// === 3D Fractal Brownian Motion for underground variation ===
float fbm3d(vec3 p) {
    float f = 0.0;
    float w = 0.5;
    for (int i = 0; i < 3; i++) {
        f += w * noise(p);
        p *= 2.0;
        w *= 0.5;
    }
    return f;
}

// === Procedural Road Network ===
// Returns distance to nearest road and the road's target height
float get_road_info(vec2 pos, float spacing, out float road_height) {
    if (spacing <= 0.0) {
        road_height = 0.0;
        return 1000.0;  // No roads
    }
    
    // Grid-based road network with some variation
    float cell_x = floor(pos.x / spacing);
    float cell_z = floor(pos.y / spacing);
    
    // Position within cell
    float local_x = mod(pos.x, spacing);
    float local_z = mod(pos.y, spacing);
    
    // Road runs along cell edges (X and Z axes)
    float dist_to_x_road = min(local_x, spacing - local_x);  // Distance to vertical road
    float dist_to_z_road = min(local_z, spacing - local_z);  // Distance to horizontal road
    
    float min_dist = min(dist_to_x_road, dist_to_z_road);
    
    // Calculate road height - follows terrain with GENTLE variation
    // Lower frequency (0.008) = slower height changes over distance
    // Smaller amplitude (3.0) = max 3 Y-levels difference = fewer steps
    float h1 = noise(vec3(cell_x * spacing, 0.0, cell_z * spacing) * 0.008) * 3.0 + 12.0;
    float h2 = noise(vec3((cell_x + 1.0) * spacing, 0.0, cell_z * spacing) * 0.008) * 3.0 + 12.0;
    float h3 = noise(vec3(cell_x * spacing, 0.0, (cell_z + 1.0) * spacing) * 0.008) * 3.0 + 12.0;
    float h4 = noise(vec3((cell_x + 1.0) * spacing, 0.0, (cell_z + 1.0) * spacing) * 0.008) * 3.0 + 12.0;
    
    // Bilinear interpolation for base height
    float tx = local_x / spacing;
    float tz = local_z / spacing;
    float interpolated_height = mix(mix(h1, h2, tx), mix(h3, h4, tx), tz);
    
    // === STEPPED ROAD WITH SMOOTH RAMPS ===
    // Creates: FLAT zones at integer Y (for block placement)
    //          RAMP zones between integers (for smooth driving)
    
    float base_level = floor(interpolated_height);
    float frac = interpolated_height - base_level;  // 0.0 to 1.0
    
    // Define how much of each level is FLAT (grid-aligned)
    // flat_size = 0.45 means 45% flat at bottom, 45% flat at top, only 10% ramp
    float flat_size = 0.45;
    
    if (frac < flat_size) {
        // FLAT ZONE at lower integer level
        road_height = base_level;
    } else if (frac > 1.0 - flat_size) {
        // FLAT ZONE at upper integer level
        road_height = base_level + 1.0;
    } else {
        // RAMP ZONE - smooth S-curve transition between integers
        // Normalize the ramp portion to 0-1
        float ramp_t = (frac - flat_size) / (1.0 - 2.0 * flat_size);
        // Apply smoothstep for S-curve (no sudden slope changes)
        ramp_t = smoothstep(0.0, 1.0, ramp_t);
        road_height = base_level + ramp_t;
    }
    
    return min_dist;
}

float get_density(vec3 pos) {
    vec3 world_pos = pos + params.chunk_offset.xyz;
    
    // Base terrain
    float base_height = params.terrain_height;
    float hill_height = noise(vec3(world_pos.x, 0.0, world_pos.z) * params.noise_freq) * params.terrain_height; 
    float terrain_height = base_height + hill_height;
    float density = world_pos.y - terrain_height;
    
    // Procedural roads
    float road_height;
    float road_dist = get_road_info(world_pos.xz, params.road_spacing, road_height);
    
    if (road_dist < params.road_width) {
        // SMOOTH ROAD SURFACE: follows the interpolated road_height directly
        // road_height already contains smooth transitions between Y levels
        // calculated in get_road_info() using smoothstep blending
        float road_density = world_pos.y - road_height;
        
        // Blend factor: 1.0 in center, 0.0 at edges
        float blend = smoothstep(params.road_width, params.road_width * 0.5, road_dist);
        
        density = mix(density, road_density, blend);
    }
    
    return density;
}

// Material IDs:
// 0 = Grass (default surface)
// 1 = Stone (underground)
// 2 = Ore (rare, deep)
// 3 = Sand (biome)
// 4 = Gravel (biome)
// 5 = Snow (biome)
// 6 = Road (asphalt)
// 100+ = Player-placed materials

uint get_material(vec3 pos, float terrain_height_at_pos) {
    vec3 world_pos = pos + params.chunk_offset.xyz;
    float depth = terrain_height_at_pos - world_pos.y;
    
    // 1. ROADS - on the road surface (height tolerance for voxel grid, tight horizontal bounds)
    float road_height;
    float road_dist = get_road_info(world_pos.xz, params.road_spacing, road_height);
    // Tight horizontal bounds (0.5x), relaxed height (2.0) to fill cracks without spillover
    float height_diff = abs(world_pos.y - road_height);
    if (road_dist < params.road_width * 0.5 && height_diff < 2.0) {
        return 6u;  // Road (asphalt)
    }
    
    // 2. Underground materials (below surface) - TRUE 3D variation
    // Extended threshold (10.0) so surface biomes extend deeper for consistency
    if (depth > 10.0) {
        // Check for ore veins using 3D noise
        float ore_noise = noise(world_pos * 0.15);
        if (ore_noise > 0.75 && depth > 8.0) {
            return 2u;  // Ore
        }
        
        // 3D stone variant noise - creates natural underground variation
        // Different positions = different stone types (deterministic)
        float stone_var = fbm3d(world_pos * 0.02);
        if (stone_var > 0.25) return 9u;  // Granite (~35-40%)
        return 1u;  // Stone (default)
    }
    
    // 3. Surface biomes - per-voxel fbm for smooth transitions
    // Shader uses same noise function for aligned visual blending
    float biome_val = fbm(world_pos.xz * 0.002);
    
    if (biome_val < -0.2) return 3u;  // Sand biome
    if (biome_val > 0.6) return 5u;   // Snow biome
    if (biome_val > 0.2) return 4u;   // Gravel biome
    
    return 0u;  // Grass (default)
}

void main() {
    uvec3 id = gl_GlobalInvocationID.xyz;
    
    // We need 33 points per axis (0..32)
    if (id.x >= 33 || id.y >= 33 || id.z >= 33) {
        return;
    }

    uint index = id.x + (id.y * 33) + (id.z * 33 * 33);
    vec3 pos = vec3(id);
    vec3 world_pos = pos + params.chunk_offset.xyz;
    
    // Calculate terrain height for material determination
    float base_height = params.terrain_height;
    float hill_height = noise(vec3(world_pos.x, 0.0, world_pos.z) * params.noise_freq) * params.terrain_height;
    float terrain_height = base_height + hill_height;
    
    // Account for road excavation in material calculation
    float road_height;
    float road_dist = get_road_info(world_pos.xz, params.road_spacing, road_height);
    float effective_height = terrain_height;
    if (road_dist < params.road_width * 2.0) {
        // Near a road - use road height as the "surface" for material depth
        float blend = smoothstep(params.road_width * 2.0, params.road_width * 0.5, road_dist);
        effective_height = mix(terrain_height, road_height, blend);
    }
    
    density_buffer.values[index] = get_density(pos);
    material_buffer.values[index] = get_material(pos, effective_height);
}

