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
    // Different logic for small vs large brushes:
    // - Small brushes: extended radius BUT only to solid voxels (prevents spill)
    // - Large brushes: simple extension (enough coverage without spill issues)
    if (params.material_id >= 0 && params.brush_value < 0.0) {
        vec3 dist_vec = abs(world_pos - params.brush_pos.xyz);
        float max_dist = max(dist_vec.x, max(dist_vec.y, dist_vec.z));
        float brush_radius = params.brush_pos.w;
        
        bool should_write = false;
        
        if (brush_radius < 1.0) {
            // SMALL BRUSH: extended radius (+0.6) but only to solid voxels
            float material_radius = brush_radius + 0.6;
            float current_density = density_buffer.values[index];
            should_write = (max_dist <= material_radius && current_density < 0.0);
        } else {
            // LARGE BRUSH: simple extension (+0.49), no solid check needed
            float material_radius = brush_radius + 0.49;
            should_write = (max_dist <= material_radius);
        }
        
        if (should_write) {
            material_buffer.values[index] = uint(params.material_id);
        }
    }
    
    // Reset material when DIGGING terrain (positive brush_value = removing solid)
    // Exposed underground voxels should show stone, not surface materials like asphalt
    if (modified && params.brush_value > 0.0) {
        // Check if the voxel is now exposed (near the new surface)
        // We reset to stone (material ID 1) for underground appearance
        float new_density = density_buffer.values[index];
        
        // Reset material for voxels that are still solid (underground) or near surface
        // This clears any surface materials like asphalt that were "painted" on top
        if (new_density < 0.5) {
            material_buffer.values[index] = 1u;  // Stone
        }
    }
}
