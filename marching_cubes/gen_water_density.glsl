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
    float noise_freq; // Unused for flat water, but kept for alignment
    float water_level; // Reused terrain_height slot
} params;

void main() {
    uvec3 id = gl_GlobalInvocationID.xyz;
    
    // We need 33 points per axis (0..32)
    if (id.x >= 33 || id.y >= 33 || id.z >= 33) {
        return;
    }

    uint index = id.x + (id.y * 33) + (id.z * 33 * 33);
    vec3 pos = vec3(id);
    vec3 world_pos = pos + params.chunk_offset.xyz;
    
    // Water density: 
    // < 0: Inside water (liquid)
    // > 0: Outside (air)
    // Surface at 0.
    
    // Simple flat plane:
    // If world_pos.y < water_level, density should be negative.
    // If world_pos.y > water_level, density should be positive.
    
    // Example: y=5, level=10 -> 5-10 = -5 (Inside)
    float density = world_pos.y - params.water_level;
    
    density_buffer.values[index] = density;
}
