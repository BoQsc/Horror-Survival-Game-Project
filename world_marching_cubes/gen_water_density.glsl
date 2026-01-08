#[compute]
#version 450

// 33x33x33 grid points to cover a 32x32x32 voxel chunk + 1 neighbor edge
layout(local_size_x = 4, local_size_y = 4, local_size_z = 4) in;

// Output: Density values
layout(set = 0, binding = 0, std430) restrict buffer DensityBuffer {
    float values[];
} density_buffer;

layout(push_constant) uniform PushConstants {
    vec4 chunk_offset; // .xyz is position
    float noise_freq; 
    float water_level; 
} params;

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
    
    // --- Regional Masking ---
    // Use low-frequency 2D noise to define "Wet Regions" (Lakes/Oceans) vs "Dry Regions".
    // 0.2 frequency of the detail noise gives large continents.
    float mask_val = noise(vec3(world_pos.x, 0.0, world_pos.z) * (params.noise_freq * 0.1));
    
    // Map 0..1 to -1..1
    mask_val = (mask_val * 2.0) - 1.0;
    
    // --- Shoreline Transition ---
    // Instead of a harsh dropoff, create a gentle slope where water meets land
    // This makes water naturally "pool" in low areas rather than having cliff edges
    
    // mask_val ranges from -1 to 1
    // We want water where mask > 0 (wet regions)
    // Smooth transition over a wider range for natural shorelines
    float water_mask = smoothstep(-0.3, 0.3, mask_val);  // 0 = dry, 1 = wet
    
    // Gently lower water level in dry areas (not a cliff, just lower)
    // Water in wet areas: at water_level
    // Water in dry areas: 20 units below (effectively underground/invisible)
    float effective_height = params.water_level - (1.0 - water_mask) * 20.0;
    
    // Density:
    // y < height -> Water (Negative)
    // y > height -> Air (Positive)
    float density = world_pos.y - effective_height;
    
    density_buffer.values[index] = density;
}