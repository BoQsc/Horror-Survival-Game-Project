#[compute]
#version 450

// Dispatch over the bounding box of the modification?
// Or just iterate the whole chunk?
// For simplicity, let's iterate the whole chunk 33x33x33.
layout(local_size_x = 4, local_size_y = 4, local_size_z = 4) in;

layout(set = 0, binding = 0, std430) restrict buffer DensityBuffer {
    float values[];
} density_buffer;

layout(push_constant) uniform PushConstants {
    vec4 chunk_offset;   // .xyz
    vec4 brush_pos;      // .xyz, .w = radius
    float brush_value;   // +1 to fill, -1 to dig
} params;

void main() {
    uvec3 id = gl_GlobalInvocationID.xyz;
    if (id.x >= 33 || id.y >= 33 || id.z >= 33) return;

    uint index = id.x + (id.y * 33) + (id.z * 33 * 33);
    
    // Current local position
    vec3 local_pos = vec3(id);
    vec3 world_pos = local_pos + params.chunk_offset.xyz;
    
    float dist = distance(world_pos, params.brush_pos.xyz);
    float radius = params.brush_pos.w;
    
    if (dist < radius) {
        // Simple hard brush or smooth? Let's do simple addition/subtraction
        // Standard: density < 0 is air, > 0 is ground? 
        // In our gen_density: return world_pos.y - terrain_height;
        // So y > height (air) is positive. y < height (ground) is negative.
        // Wait, if y=10, height=5 -> 5 (Air). if y=0, height=5 -> -5 (Ground).
        // ISO_LEVEL is 0.0.
        // Digging (removing ground) means making values POSITIVE (towards air).
        // Placing (adding ground) means making values NEGATIVE.
        
        // Smooth falloff
        float falloff = 1.0 - (dist / radius);
        falloff = clamp(falloff, 0.0, 1.0);
        
        // If brush_value > 0 (dig), we add to density.
        // If brush_value < 0 (place), we subtract.
        
        // Apply
        float modification = params.brush_value * falloff * 1.0; // Speed factor
        density_buffer.values[index] += modification;
    }
}
