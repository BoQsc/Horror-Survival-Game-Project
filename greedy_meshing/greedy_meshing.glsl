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

void add_quad(vec3 p0, vec3 p1, vec3 p2, vec3 p3, vec3 normal, vec2 uv0, vec2 uv1, vec2 uv2, vec2 uv3) {
    uint v_idx = atomicAdd(vertex_count, 4);
    
    // Vertices (Write as floats)
    // Godot uses Clockwise winding for front faces by default (or Counter-Clockwise depending on setup).
    // Swapping p1 and p3 effectively reverses the winding order.
    uint v_ptr = v_idx * 3;
    
    // Vertex 0 (p0)
    vertices[v_ptr + 0] = p0.x;
    vertices[v_ptr + 1] = p0.y;
    vertices[v_ptr + 2] = p0.z;
    
    // Vertex 1 (Now p3 - Swapped)
    vertices[v_ptr + 3] = p3.x;
    vertices[v_ptr + 4] = p3.y;
    vertices[v_ptr + 5] = p3.z;
    
    // Vertex 2 (p2)
    vertices[v_ptr + 6] = p2.x;
    vertices[v_ptr + 7] = p2.y;
    vertices[v_ptr + 8] = p2.z;
    
    // Vertex 3 (Now p1 - Swapped)
    vertices[v_ptr + 9] = p1.x;
    vertices[v_ptr + 10] = p1.y;
    vertices[v_ptr + 11] = p1.z;
    
    // Normals (Write as floats)
    // Same normal for all vertices
    normals[v_ptr + 0] = normal.x;
    normals[v_ptr + 1] = normal.y;
    normals[v_ptr + 2] = normal.z;
    
    normals[v_ptr + 3] = normal.x;
    normals[v_ptr + 4] = normal.y;
    normals[v_ptr + 5] = normal.z;
    
    normals[v_ptr + 6] = normal.x;
    normals[v_ptr + 7] = normal.y;
    normals[v_ptr + 8] = normal.z;
    
    normals[v_ptr + 9] = normal.x;
    normals[v_ptr + 10] = normal.y;
    normals[v_ptr + 11] = normal.z;
    
    // UVs (Swap uv1 and uv3 to match vertex swap)
    uvs[v_idx + 0] = uv0;
    uvs[v_idx + 1] = uv3;
    uvs[v_idx + 2] = uv2;
    uvs[v_idx + 3] = uv1;
    
    // Indices
    // 0-1-2 and 0-2-3 (Standard Quad triangulation)
    // Since we swapped the vertex positions in the buffer, we can keep standard index order
    // and the physical triangle winding on screen will be reversed.
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
    
    // If current voxel is empty, skip
    if (!is_voxel_solid(id)) {
        return;
    }
    
    vec3 pos = vec3(id);
    
    // Corner points of the voxel
    vec3 p000 = pos + vec3(0.0, 0.0, 0.0);
    vec3 p100 = pos + vec3(1.0, 0.0, 0.0);
    vec3 p010 = pos + vec3(0.0, 1.0, 0.0);
    vec3 p110 = pos + vec3(1.0, 1.0, 0.0);
    vec3 p001 = pos + vec3(0.0, 0.0, 1.0);
    vec3 p101 = pos + vec3(1.0, 0.0, 1.0);
    vec3 p011 = pos + vec3(0.0, 1.0, 1.0);
    vec3 p111 = pos + vec3(1.0, 1.0, 1.0);
    
    // Check 6 neighbors and generate faces if exposed
    
    // +X Face (Right)
    if (!is_voxel_solid(id + ivec3(1, 0, 0))) {
        add_quad(p101, p100, p110, p111, vec3(1, 0, 0), vec2(0, 0), vec2(1, 0), vec2(1, 1), vec2(0, 1));
    }
    
    // -X Face (Left)
    if (!is_voxel_solid(id + ivec3(-1, 0, 0))) {
        add_quad(p000, p001, p011, p010, vec3(-1, 0, 0), vec2(0, 0), vec2(1, 0), vec2(1, 1), vec2(0, 1));
    }
    
    // +Y Face (Top)
    if (!is_voxel_solid(id + ivec3(0, 1, 0))) {
        add_quad(p011, p111, p110, p010, vec3(0, 1, 0), vec2(0, 0), vec2(1, 0), vec2(1, 1), vec2(0, 1));
    }
    
    // -Y Face (Bottom)
    if (!is_voxel_solid(id + ivec3(0, -1, 0))) {
        add_quad(p001, p000, p100, p101, vec3(0, -1, 0), vec2(0, 0), vec2(1, 0), vec2(1, 1), vec2(0, 1));
    }
    
    // +Z Face (Front)
    if (!is_voxel_solid(id + ivec3(0, 0, 1))) {
        add_quad(p101, p111, p011, p001, vec3(0, 0, 1), vec2(0, 0), vec2(1, 0), vec2(1, 1), vec2(0, 1));
    }
    
    // -Z Face (Back)
    if (!is_voxel_solid(id + ivec3(0, 0, -1))) {
        add_quad(p000, p100, p110, p010, vec3(0, 0, -1), vec2(0, 0), vec2(1, 0), vec2(1, 1), vec2(0, 1));
    }
}

