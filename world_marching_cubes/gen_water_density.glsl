#[compute]
#version 450

// 33x33x33 grid points to cover a 32x32x32 voxel chunk + 1 neighbor edge
layout(local_size_x = 4, local_size_y = 4, local_size_z = 4) in;

// Output: Density values
layout(set = 0, binding = 0, std430) restrict buffer DensityBuffer {
    float values[];
} density_buffer;

// Water map buffer (set 1) — R8 bytes packed as uint, 255 = water, 0 = dry
layout(set = 1, binding = 0, std430) restrict readonly buffer WaterMapBuffer {
    uint values[];
} water_map_buf;

layout(push_constant) uniform PushConstants {
    vec4 chunk_offset; // .xyz is position
    float noise_freq; 
    float water_level;
    float use_world_map; // >0.5 = read from water map buffer
    float map_size;      // 2048.0
    float map_half;      // 1024.0
    float _pad0;
} params;

// Read a single byte from a packed uint buffer at pixel index
uint read_water_byte(uint idx) {
    uint word_idx = idx / 4u;
    uint byte_offset = idx % 4u;
    uint word = water_map_buf.values[word_idx];
    return (word >> (byte_offset * 8u)) & 0xFFu;
}

// Reuse the noise function for consistency
float hash(vec3 p) {
    p = fract(p * 0.3183099 + .1);
    p *= 17.0;
    return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
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

void main() {
    uvec3 id = gl_GlobalInvocationID.xyz;
    
    // We need 33 points per axis (0..32)
    if (id.x >= 33 || id.y >= 33 || id.z >= 33) {
        return;
    }

    uint index = id.x + (id.y * 33) + (id.z * 33 * 33);
    vec3 pos = vec3(id);
    vec3 world_pos = pos + params.chunk_offset.xyz;
    
    // === WORLD MAP MODE: use water map ===
    if (params.use_world_map > 0.5) {
        float px = clamp(world_pos.x + params.map_half, 0.0, params.map_size - 1.0);
        float pz = clamp(world_pos.z + params.map_half, 0.0, params.map_size - 1.0);
        uint map_idx = uint(pz) * uint(params.map_size) + uint(px);
        uint water_val = read_water_byte(map_idx);
        
        if (water_val > 128u) {
            // Water pixel — water at water_level
            density_buffer.values[index] = world_pos.y - params.water_level;
        } else {
            // Dry pixel — no water (push underground so it's invisible)
            density_buffer.values[index] = 100.0;
        }
        return;
    }
    
    // === PROCEDURAL MODE: noise-based regional masking ===
    // --- Regional Masking ---
    // Use low-frequency 2D noise to define "Wet Regions" (Lakes/Oceans) vs "Dry Regions".
    float mask_val = noise(vec3(world_pos.x, 0.0, world_pos.z) * (params.noise_freq * 0.1));
    
    // Map 0..1 to -1..1
    mask_val = (mask_val * 2.0) - 1.0;
    
    // --- Shoreline Transition ---
    float water_mask = smoothstep(-0.3, 0.3, mask_val);
    
    // Water in wet areas: at water_level
    // Water in dry areas: 20 units below (effectively underground/invisible)
    float effective_height = params.water_level - (1.0 - water_mask) * 20.0;
    
    float density = world_pos.y - effective_height;
    
    density_buffer.values[index] = density;
}