#[compute]
#version 450

// Dispatch over the whole chunk 33x33x33.
layout(local_size_x = 4, local_size_y = 4, local_size_z = 4) in;

layout(set = 0, binding = 0, std430) restrict buffer DensityBuffer {
    float values[];
} density_buffer;

layout(set = 0, binding = 1, std430) restrict buffer MaterialBuffer {
    uint values[];
} material_buffer;

layout(push_constant) uniform PushConstants {
    vec4 chunk_offset;   // .xyz = position, .w unused
    vec4 brush_pos;      // .xyz = world pos, .w = radius
    float brush_value;   // +1 to dig, -1 to place
    int shape_type;      // 0 = Sphere, 1 = Box
    int material_id;     // -1 = no change, 0+ = specific material
    float _padding;      // Keep 48 byte alignment
} params;

void main() {
    uvec3 id = gl_GlobalInvocationID.xyz;
    if (id.x >= 33 || id.y >= 33 || id.z >= 33) return;

    uint index = id.x + (id.y * 33) + (id.z * 33 * 33);
    
    vec3 local_pos = vec3(id);
    vec3 world_pos = local_pos + params.chunk_offset.xyz;
    
    bool modified = false;
    
    if (params.shape_type == 1) {
        // Box Shape (Hard edges)
        vec3 dist_vec = abs(world_pos - params.brush_pos.xyz);
        float max_dist = max(dist_vec.x, max(dist_vec.y, dist_vec.z));
        
        if (max_dist <= params.brush_pos.w) {
            density_buffer.values[index] = params.brush_value;
            modified = true;
        }
    } else {
        // Sphere Shape (Smooth falloff)
        float dist = distance(world_pos, params.brush_pos.xyz);
        float radius = params.brush_pos.w;
        
        if (dist < radius) {
            float falloff = 1.0 - (dist / radius);
            float weight = clamp(falloff, 0.0, 1.0);
            float modification = params.brush_value * weight;
            density_buffer.values[index] += modification;
            modified = true;
        }
    }
    
    // Write material when PLACING terrain (negative brush_value = adding solid)
    // Extended material radius (+1.5) but ONLY to solid voxels
    // This covers boundary voxels without spilling onto air/distant terrain
    if (params.material_id >= 0 && params.brush_value < 0.0) {
        vec3 dist_vec = abs(world_pos - params.brush_pos.xyz);
        float max_dist = max(dist_vec.x, max(dist_vec.y, dist_vec.z));
        float material_radius = params.brush_pos.w + 0.6;  // Extended radius for small brush support
        
        // Read the CURRENT density (after modification above)
        float current_density = density_buffer.values[index];
        
        // Only write material if within extended radius AND voxel is SOLID
        // This prevents spilling onto distant/air terrain
        if (max_dist <= material_radius && current_density < 0.0) {
            material_buffer.values[index] = uint(params.material_id);
        }
    }
}
