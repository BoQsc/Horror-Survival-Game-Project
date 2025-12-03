#[compute]
#version 450
// Godot 4.x Compute Shader Template

layout(binding = 0) uniform sampler3D voxel_data; // Input: 3D texture for voxel data

layout(push_constant) uniform Params {
    ivec3 voxel_grid_size_uniform; // Input: Size of the voxel grid
};

// Output (e.g., Mesh Data)
// std430 aligns vec3 to 16 bytes. Godot expects 12 bytes. We must use float arrays to pack tightly.
layout(std430, binding = 1) writeonly buffer MeshVertices { float vertices[]; };
layout(std430, binding = 2) writeonly buffer MeshNormals { float normals[]; };
layout(std430, binding = 3) writeonly buffer MeshUVs { vec2 uvs[]; };
layout(std430, binding = 4) writeonly buffer MeshIndices { uint indices[]; };
layout(std430, binding = 5) coherent buffer Counter { uint vertex_count; };

// Global work group size for compute shaders.
layout(local_size_x = 4, local_size_y = 4, local_size_z = 4) in;

bool is_voxel_solid(ivec3 pos) {
    if (pos.x < 0 || pos.y < 0 || pos.z < 0 ||
        pos.x >= voxel_grid_size_uniform.x ||
        pos.y >= voxel_grid_size_uniform.y ||
        pos.z >= voxel_grid_size_uniform.z) {
        return false;
    }
    return texelFetch(voxel_data, pos, 0).r > 0.0;
}

// Checks if a specific face exists at 'pos' facing 'normal' direction
// A face exists if 'pos' is solid and 'pos + normal' is empty.
bool has_face(ivec3 pos, ivec3 normal) {
    if (!is_voxel_solid(pos)) return false;
    if (is_voxel_solid(pos + normal)) return false;
    return true;
}

void add_quad(vec3 origin, vec3 u_axis, vec3 v_axis, float u_len, float v_len, vec3 normal) {
    uint v_idx = atomicAdd(vertex_count, 4);
    uint v_ptr = v_idx * 3;
    
    // Calculate corners based on origin and axes
    vec3 p0 = origin;
    vec3 p1 = origin + u_axis * u_len;
    vec3 p2 = origin + u_axis * u_len + v_axis * v_len;
    vec3 p3 = origin + v_axis * v_len;
    
    // Vertices (Write as floats)
    // Godot CW Winding: p0 -> p3 -> p2 -> p1 (Swapping 1 and 3 from standard CCW)
    
    // Vertex 0 (p0)
    vertices[v_ptr + 0] = p0.x; vertices[v_ptr + 1] = p0.y; vertices[v_ptr + 2] = p0.z;
    // Vertex 1 (p3) - Swapped
    vertices[v_ptr + 3] = p3.x; vertices[v_ptr + 4] = p3.y; vertices[v_ptr + 5] = p3.z;
    // Vertex 2 (p2)
    vertices[v_ptr + 6] = p2.x; vertices[v_ptr + 7] = p2.y; vertices[v_ptr + 8] = p2.z;
    // Vertex 3 (p1) - Swapped
    vertices[v_ptr + 9] = p1.x; vertices[v_ptr + 10] = p1.y; vertices[v_ptr + 11] = p1.z;
    
    // Normals
    for (int i = 0; i < 4; i++) {
        normals[v_ptr + i*3 + 0] = normal.x;
        normals[v_ptr + i*3 + 1] = normal.y;
        normals[v_ptr + i*3 + 2] = normal.z;
    }
    
    // UVs (Scalable)
    // We map UVs to physical size so textures tile correctly
    vec2 uv0 = vec2(0.0, 0.0);
    vec2 uv1 = vec2(u_len, 0.0);
    vec2 uv2 = vec2(u_len, v_len);
    vec2 uv3 = vec2(0.0, v_len);
    
    // Swap uv1 and uv3 to match vertex swap
    uvs[v_idx + 0] = uv0;
    uvs[v_idx + 1] = uv3;
    uvs[v_idx + 2] = uv2;
    uvs[v_idx + 3] = uv1;
    
    // Indices
    uint quad_idx = v_idx / 4;
    uint i_idx = quad_idx * 6;
    
    indices[i_idx + 0] = v_idx + 0;
    indices[i_idx + 1] = v_idx + 1;
    indices[i_idx + 2] = v_idx + 2;
    indices[i_idx + 3] = v_idx + 0;
    indices[i_idx + 4] = v_idx + 2;
    indices[i_idx + 5] = v_idx + 3;
}

void main() {
    ivec3 id = ivec3(gl_GlobalInvocationID.xyz);
    
    if (id.x >= voxel_grid_size_uniform.x ||
        id.y >= voxel_grid_size_uniform.y ||
        id.z >= voxel_grid_size_uniform.z) {
        return;
    }
    
    vec3 pos = vec3(id);
    
    // 1. +X Face (Right)
    // Merge along Z axis
    ivec3 normal = ivec3(1, 0, 0);
    if (has_face(id, normal)) {
        // Check previous in merge direction (Z-1)
        if (!has_face(id - ivec3(0,0,1), normal)) {
            // Start of strip. Loop forward.
            float len = 1.0;
            for (int k = 1; k < voxel_grid_size_uniform.z - id.z; k++) {
                if (has_face(id + ivec3(0,0,k), normal)) {
                    len += 1.0;
                } else {
                    break;
                }
            }
            // Origin(1,1,0), U(0,0,1), V(0,-1,0)
            add_quad(pos + vec3(1,1,0), vec3(0,0,1), vec3(0,-1,0), len, 1.0, vec3(1,0,0));
        }
    }
    
    // 2. -X Face (Left)
    // Merge along Z axis
    normal = ivec3(-1, 0, 0);
    if (has_face(id, normal)) {
        if (!has_face(id - ivec3(0,0,1), normal)) {
            float len = 1.0;
            for (int k = 1; k < voxel_grid_size_uniform.z - id.z; k++) {
                if (has_face(id + ivec3(0,0,k), normal)) {
                    len += 1.0;
                } else {
                    break;
                }
            }
            // Origin(0,0,0), U(0,0,1), V(0,1,0)
            add_quad(pos, vec3(0,0,1), vec3(0,1,0), len, 1.0, vec3(-1,0,0));
        }
    }
    
    // 3. +Y Face (Top)
    // Merge along X axis
    normal = ivec3(0, 1, 0);
    if (has_face(id, normal)) {
        if (!has_face(id - ivec3(1,0,0), normal)) {
            float len = 1.0;
            for (int k = 1; k < voxel_grid_size_uniform.x - id.x; k++) {
                if (has_face(id + ivec3(k,0,0), normal)) {
                    len += 1.0;
                } else {
                    break;
                }
            }
            // Origin(0,1,1), U(1,0,0), V(0,0,-1)
            add_quad(pos + vec3(0,1,1), vec3(1,0,0), vec3(0,0,-1), len, 1.0, vec3(0,1,0));
        }
    }
    
    // 4. -Y Face (Bottom)
    // Merge along X axis
    normal = ivec3(0, -1, 0);
    if (has_face(id, normal)) {
        if (!has_face(id - ivec3(1,0,0), normal)) {
            float len = 1.0;
            for (int k = 1; k < voxel_grid_size_uniform.x - id.x; k++) {
                if (has_face(id + ivec3(k,0,0), normal)) {
                    len += 1.0;
                } else {
                    break;
                }
            }
            // Origin(0,0,0), U(1,0,0), V(0,0,1)
            add_quad(pos, vec3(1,0,0), vec3(0,0,1), len, 1.0, vec3(0,-1,0));
        }
    }
    
    // 5. +Z Face (Front)
    // Merge along X axis
    normal = ivec3(0, 0, 1);
    if (has_face(id, normal)) {
        if (!has_face(id - ivec3(1,0,0), normal)) {
            float len = 1.0;
            for (int k = 1; k < voxel_grid_size_uniform.x - id.x; k++) {
                if (has_face(id + ivec3(k,0,0), normal)) {
                    len += 1.0;
                } else {
                    break;
                }
            }
            // Origin(0,0,1), U(1,0,0), V(0,1,0)
            add_quad(pos + vec3(0,0,1), vec3(1,0,0), vec3(0,1,0), len, 1.0, vec3(0,0,1));
        }
    }
    
    // 6. -Z Face (Back)
    // Merge along X axis
    normal = ivec3(0, 0, -1);
    if (has_face(id, normal)) {
        if (!has_face(id - ivec3(1,0,0), normal)) {
            float len = 1.0;
            for (int k = 1; k < voxel_grid_size_uniform.x - id.x; k++) {
                if (has_face(id + ivec3(k,0,0), normal)) {
                    len += 1.0;
                } else {
                    break;
                }
            }
            // Origin(0,1,0), U(1,0,0), V(0,-1,0)
            add_quad(pos + vec3(0,1,0), vec3(1,0,0), vec3(0,-1,0), len, 1.0, vec3(0,0,-1));
        }
    }
}
