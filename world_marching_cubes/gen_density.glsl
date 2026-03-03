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
    vec4 chunk_offset; // .xyz is position, .w is wide_shoulders
    float noise_freq;
    float terrain_height;
    float road_spacing;  // Grid spacing for roads (0 = no procedural roads)
    float road_width;    // Width of roads
    float use_world_map; // >0.5 = read from world map buffers instead of noise
    float map_size;      // 2048.0 (pixels = meters)
    float map_half;      // 1024.0 (center offset)
    float max_height;    // terrain_height * 2.5 (height normalization)
} params;

// === World Map Buffers (set 1) — uploaded from editor PNGs ===
// Only bound when use_world_map > 0.5
layout(set = 1, binding = 0, std430) restrict readonly buffer HeightmapBuffer {
    uint values[];  // R8 bytes packed as uint (4 pixels per uint)
} heightmap_buf;

layout(set = 1, binding = 1, std430) restrict readonly buffer BiomeBuffer {
    uint values[];  // R8 biome IDs packed as uint
} biome_buf;

layout(set = 1, binding = 2, std430) restrict readonly buffer RoadBuffer {
    uint values[];  // RG8 packed: R=is_road, G=road_height
} road_buf;

// Read a single byte from a packed uint buffer at pixel index
uint read_byte(uint idx, uint buffer_type) {
    uint word_idx = idx / 4u;
    uint byte_offset = idx % 4u;
    uint word;
    if (buffer_type == 0u) word = heightmap_buf.values[word_idx];
    else if (buffer_type == 1u) word = biome_buf.values[word_idx];
    else word = road_buf.values[word_idx];
    return (word >> (byte_offset * 8u)) & 0xFFu;
}

// Sample world map height at world XZ (returns terrain height in world units)
float sample_world_height(vec2 world_xz) {
    float px = clamp(world_xz.x + params.map_half, 0.0, params.map_size - 1.0);
    float pz = clamp(world_xz.y + params.map_half, 0.0, params.map_size - 1.0);
    uint idx = uint(pz) * uint(params.map_size) + uint(px);
    float h_norm = float(read_byte(idx, 0u)) / 255.0;
    return h_norm * params.max_height;
}

// Sample world map biome at world XZ (returns material ID)
uint sample_world_biome(vec2 world_xz) {
    float px = clamp(world_xz.x + params.map_half, 0.0, params.map_size - 1.0);
    float pz = clamp(world_xz.y + params.map_half, 0.0, params.map_size - 1.0);
    uint idx = uint(pz) * uint(params.map_size) + uint(px);
    return read_byte(idx, 1u);
}

// Sample world map road at world XZ (returns vec2: x=is_road[0-255], y=road_height_byte)
vec2 sample_world_road(vec2 world_xz) {
    float px = clamp(world_xz.x + params.map_half, 0.0, params.map_size - 1.0);
    float pz = clamp(world_xz.y + params.map_half, 0.0, params.map_size - 1.0);
    uint idx = uint(pz) * uint(params.map_size) + uint(px);
    // RG8: 2 bytes per pixel
    uint byte_idx = idx * 2u;
    uint word_idx = byte_idx / 4u;
    uint byte_off = byte_idx % 4u;
    uint word = road_buf.values[word_idx];
    float r = float((word >> (byte_off * 8u)) & 0xFFu);
    float g = float((word >> ((byte_off + 1u) * 8u)) & 0xFFu);
    return vec2(r, g);
}

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
    
    // === WORLD MAP MODE: read height from PNG buffer ===
    if (params.use_world_map > 0.5) {
        // --- Boundary wall: solid wall at map edges ---
        float edge_margin = 4.0;  // Wall thickness in voxels
        float dist_to_edge_x = min(world_pos.x + params.map_half, params.map_half - world_pos.x);
        float dist_to_edge_z = min(world_pos.z + params.map_half, params.map_half - world_pos.z);
        float dist_to_edge = min(dist_to_edge_x, dist_to_edge_z);
        
        if (dist_to_edge <= 0.0) {
            return -10.0;  // Fully solid beyond boundary
        }
        if (dist_to_edge < edge_margin) {
            // Wall rises from terrain to sky as we approach the edge
            float wall_blend = 1.0 - (dist_to_edge / edge_margin);  // 0 at margin, 1 at edge
            float wall_height = mix(28.0, 32.0, wall_blend);  // Rise to chunk top
            if (world_pos.y > wall_height) {
                return world_pos.y - wall_height;  // Air above wall top
            }
            return -10.0 * wall_blend;  // Increasingly solid near edge
        }
        
        float map_height = sample_world_height(world_pos.xz);
        // Clamp height to fit within Y=0 chunk (0-32 voxels).
        // Without this, heights >32 have no isosurface in the chunk → see-through holes.
        map_height = clamp(map_height, 1.0, 28.0);
        return world_pos.y - map_height;
    }
    
    // === PROCEDURAL MODE: compute from noise ===
    // Base terrain
    float base_height = params.terrain_height;
    float hill_height = noise(vec3(world_pos.x, 0.0, world_pos.z) * params.noise_freq) * params.terrain_height; 
    float terrain_height = base_height + hill_height;
    float density = world_pos.y - terrain_height;
    
    // Procedural roads - expanded flattened area to accommodate buildings alongside roads
    float road_height;
    float road_dist = get_road_info(world_pos.xz, params.road_spacing, road_height);
    
    // Check if wide shoulders toggle is active (> 0.5)
    bool use_wide_shoulders = params.chunk_offset.w > 0.5;
    
    // Widen the flattened area to accommodate buildings (houses spawn up to ~14 blocks from road center)
    float flatten_width = use_wide_shoulders ? (params.road_width + 25.0) : params.road_width;
    float flat_zone_end = use_wide_shoulders ? (params.road_width * 0.5 + 15.0) : (params.road_width * 0.5);
    
    if (road_dist < flatten_width) {
        // SMOOTH ROAD SURFACE: follows the interpolated road_height directly
        float road_density = world_pos.y - road_height;
        
        // Blend factor: 1.0 in flat zone, blending to 0.0 at the edge of the flatten_width
        float blend = smoothstep(flatten_width, flat_zone_end, road_dist);
        
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
    
    // === WORLD MAP MODE: read biome from PNG buffer ===
    if (params.use_world_map > 0.5) {
        // Underground: still use procedural stone/ore
        if (depth > 10.0) {
            float ore_noise = noise(world_pos * 0.15);
            if (ore_noise > 0.75 && depth > 8.0) return 2u;
            float stone_var = fbm3d(world_pos * 0.02);
            if (stone_var > 0.25) return 9u;
            return 1u;
        }
        // Check road buffer — roads override biome (only top 2 blocks, like procedural mode)
        vec2 road_data = sample_world_road(world_pos.xz);
        if (road_data.x > 128.0 && depth < 2.0) {
            return 6u;  // Road (asphalt)
        }
        // Biome: use same GPU fbm() as procedural mode for perfect shader alignment
        float biome_val = fbm(world_pos.xz * 0.002);
        if (biome_val < -0.2) return 3u;      // Sand
        if (biome_val > 0.6) return 5u;        // Snow
        if (biome_val > 0.2) return 4u;        // Gravel
        return 0u;                              // Grass
    }
    
    // === PROCEDURAL MODE ===
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
    float terrain_height;
    if (params.use_world_map > 0.5) {
        terrain_height = clamp(sample_world_height(world_pos.xz), 1.0, 28.0);
    } else {
        float base_height = params.terrain_height;
        float hill_height = noise(vec3(world_pos.x, 0.0, world_pos.z) * params.noise_freq) * params.terrain_height;
        terrain_height = base_height + hill_height;
    }
    
    // Material depth is strictly based on the original terrain surface to prevent rectangular stone artifacts around roads
    density_buffer.values[index] = get_density(pos);
    material_buffer.values[index] = get_material(pos, terrain_height);
}

