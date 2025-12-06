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
    int shape_type;      // 0 = Sphere, 1 = Box
    vec2 _padding;
} params;

void main() {
    uvec3 id = gl_GlobalInvocationID.xyz;
    if (id.x >= 33 || id.y >= 33 || id.z >= 33) return;

    uint index = id.x + (id.y * 33) + (id.z * 33 * 33);
    
    // Current local position
    vec3 local_pos = vec3(id);
    vec3 world_pos = local_pos + params.chunk_offset.xyz;
    
    float weight = 0.0;
    
    if (params.shape_type == 1) {
        // Box Shape (Hard edges)
        // Check if point is inside the box defined by center brush_pos.xyz and radius brush_pos.w
        vec3 dist_vec = abs(world_pos - params.brush_pos.xyz);
        float max_dist = max(dist_vec.x, max(dist_vec.y, dist_vec.z));
        
        if (max_dist <= params.brush_pos.w) {
            // Hard Set for Blocky Mode
            density_buffer.values[index] = params.brush_value;
        }
    } else {
        // Sphere Shape (Smooth falloff)
        float dist = distance(world_pos, params.brush_pos.xyz);
        float radius = params.brush_pos.w;
        
        if (dist < radius) {
            float falloff = 1.0 - (dist / radius);
            weight = clamp(falloff, 0.0, 1.0);
            
             // Accumulate for Smooth Mode
            float modification = params.brush_value * weight * 1.0;
            density_buffer.values[index] += modification;
        }
    }
}
