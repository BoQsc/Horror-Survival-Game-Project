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
    
    // Improved Water Generation
    // Instead of full 3D Swiss Cheese which might float everywhere,
    // let's define a perturbed surface height.
    
    // Use noise to displace the water level up/down
    float n_val = noise(world_pos * params.noise_freq); // 0..1
    n_val = (n_val * 2.0) - 1.0; // -1..1
    
    // Amplitude of waves/hills for water surface
    float wave_amp = 4.0; 
    
    float surface_height = params.water_level + (n_val * wave_amp);
    
    // Density:
    // y < surface -> Water (Negative)
    // y > surface -> Air (Positive)
    float density = world_pos.y - surface_height;
    
    density_buffer.values[index] = density;
}
