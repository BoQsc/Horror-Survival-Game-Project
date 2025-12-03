#[compute]
#version 450

layout(local_size_x = 4, local_size_y = 4, local_size_z = 4) in;

layout(binding = 0) uniform sampler3D voxel_data;

layout(push_constant) uniform Params {
    ivec3 voxel_grid_size_uniform;
};

layout(std430, binding = 1) writeonly buffer MeshVertices { float vertices[]; };
layout(std430, binding = 2) writeonly buffer MeshNormals { float normals[]; };
layout(std430, binding = 3) writeonly buffer MeshUVs { vec2 uvs[]; };
layout(std430, binding = 4) writeonly buffer MeshIndices { uint indices[]; };
layout(std430, binding = 5) coherent buffer Counter { uint vertex_count; };
// We add a new counter for indices because Quad vs Tri index count differs
layout(std430, binding = 6) coherent buffer IndexCounter { uint index_count; };

uint get_voxel(ivec3 pos) {
    if (pos.x < 0 || pos.y < 0 || pos.z < 0 ||
        pos.x >= voxel_grid_size_uniform.x ||
        pos.y >= voxel_grid_size_uniform.y ||
        pos.z >= voxel_grid_size_uniform.z) {
        return 0u;
    }
    return uint(round(texelFetch(voxel_data, pos, 0).r));
}

bool has_face_type(ivec3 pos, ivec3 normal, uint type) {
    if (get_voxel(pos) != type) return false;
    if (get_voxel(pos + normal) == type) return false;
    return true;
}

void add_triangle(vec3 p0, vec3 p1, vec3 p2, vec3 normal, vec2 uv0, vec2 uv1, vec2 uv2) {
    uint v_idx = atomicAdd(vertex_count, 3);
    uint i_idx = atomicAdd(index_count, 3);
    
    uint v_ptr = v_idx * 3;
    
    // CW: p0 -> p2 -> p1
    vertices[v_ptr + 0] = p0.x; vertices[v_ptr + 1] = p0.y; vertices[v_ptr + 2] = p0.z;
    vertices[v_ptr + 3] = p2.x; vertices[v_ptr + 4] = p2.y; vertices[v_ptr + 5] = p2.z;
    vertices[v_ptr + 6] = p1.x; vertices[v_ptr + 7] = p1.y; vertices[v_ptr + 8] = p1.z;
    
    for (int i = 0; i < 3; i++) {
        normals[v_ptr + i*3 + 0] = normal.x;
        normals[v_ptr + i*3 + 1] = normal.y;
        normals[v_ptr + i*3 + 2] = normal.z;
    }
    
    uvs[v_idx + 0] = uv0;
    uvs[v_idx + 1] = uv2;
    uvs[v_idx + 2] = uv1;
    
    indices[i_idx + 0] = v_idx + 0;
    indices[i_idx + 1] = v_idx + 1;
    indices[i_idx + 2] = v_idx + 2;
}

void add_quad(vec3 origin, vec3 u_axis, vec3 v_axis, float u_len, float v_len, vec3 normal) {
    uint v_idx = atomicAdd(vertex_count, 4);
    uint i_idx = atomicAdd(index_count, 6);
    
    uint v_ptr = v_idx * 3;
    
    vec3 p0 = origin;
    vec3 p1 = origin + u_axis * u_len;
    vec3 p2 = origin + u_axis * u_len + v_axis * v_len;
    vec3 p3 = origin + v_axis * v_len;
    
    // CW: p0 -> p3 -> p2 -> p1
    vertices[v_ptr + 0] = p0.x; vertices[v_ptr + 1] = p0.y; vertices[v_ptr + 2] = p0.z;
    vertices[v_ptr + 3] = p3.x; vertices[v_ptr + 4] = p3.y; vertices[v_ptr + 5] = p3.z;
    vertices[v_ptr + 6] = p2.x; vertices[v_ptr + 7] = p2.y; vertices[v_ptr + 8] = p2.z;
    vertices[v_ptr + 9] = p1.x; vertices[v_ptr + 10] = p1.y; vertices[v_ptr + 11] = p1.z;
    
    for (int i = 0; i < 4; i++) {
        normals[v_ptr + i*3 + 0] = normal.x;
        normals[v_ptr + i*3 + 1] = normal.y;
        normals[v_ptr + i*3 + 2] = normal.z;
    }
    
    vec2 uv0 = vec2(0.0, 0.0);
    vec2 uv1 = vec2(u_len, 0.0);
    vec2 uv2 = vec2(u_len, v_len);
    vec2 uv3 = vec2(0.0, v_len);
    
    uvs[v_idx + 0] = uv0;
    uvs[v_idx + 1] = uv3;
    uvs[v_idx + 2] = uv2;
    uvs[v_idx + 3] = uv1;
    
    indices[i_idx + 0] = v_idx + 0;
    indices[i_idx + 1] = v_idx + 1;
    indices[i_idx + 2] = v_idx + 2;
    
    indices[i_idx + 3] = v_idx + 0;
    indices[i_idx + 4] = v_idx + 2;
    indices[i_idx + 5] = v_idx + 3;
}

void add_ramp(vec3 pos) {
    vec3 p000 = pos + vec3(0,0,0);
    vec3 p100 = pos + vec3(1,0,0);
    vec3 p011 = pos + vec3(0,1,1);
    vec3 p111 = pos + vec3(1,1,1);
    vec3 p001 = pos + vec3(0,0,1);
    vec3 p101 = pos + vec3(1,0,1);
    
    // Slope Face (Up/North)
    // Normal should be (0, 1, -1) roughly.
    // Origin p000. U(0,1,1). V(1,0,0).
    // U x V = (0,1,1) x (1,0,0) = (0, 1, -1). Correct (Up-North).
    vec3 slope_n = normalize(vec3(0, 1, -1));
    add_quad(p000, vec3(0,1,1), vec3(1,0,0), 1.0, 1.0, slope_n);
    
    // Back Face (+Z)
    // Normal (0,0,1).
    // p001 -> p101 -> p111 -> p011
    // U(1,0,0). V(0,1,0). U x V = (0,0,1). Correct.
    add_quad(p001, vec3(1,0,0), vec3(0,1,0), 1.0, 1.0, vec3(0,0,1));
    
    // Bottom Face (-Y)
    // Normal (0,-1,0).
    // p000 -> p100 -> p101 -> p001
    // U(1,0,0). V(0,0,1). U x V = (0,-1,0). Correct.
    add_quad(p000, vec3(1,0,0), vec3(0,0,1), 1.0, 1.0, vec3(0,-1,0));
    
    // Left Side (-X)
    // Normal (-1, 0, 0).
    // Triangle p000 -> p011 -> p001
    // V1(0,1,1). V2(0,0,1).
    // V1 x V2 = (1,0,0) -> +X (Wrong).
    // Swap: p000 -> p001 -> p011
    // V1(0,0,1). V2(0,1,1).
    // V1 x V2 = (-1,0,0). Correct.
    // My previous replacement instruction said swap... let's re-verify.
    // Previous code was p000, p001, p011. This IS correct winding (-X).
    // So why did it look wrong? Maybe add_triangle logic?
    // add_triangle outputs CW (p0, p2, p1).
    // Input p000, p001, p011 (CCW). Output p000, p011, p001 (CW).
    // This *should* be visible from outside.
    // Let's keep standard CCW input order for safety:
    add_triangle(p000, p001, p011, vec3(-1,0,0), vec2(0,0), vec2(1,0), vec2(1,1));
    
    // Right Side (+X)
    // Normal (1, 0, 0).
    // Triangle p100 -> p111 -> p101
    // V1(0,1,1). V2(0,0,1).
    // V1 x V2 = (1,0,0). Correct.
    // Input is CCW.
    add_triangle(p100, p111, p101, vec3(1,0,0), vec2(0,0), vec2(1,1), vec2(1,0));
}

void main() {
    ivec3 id = ivec3(gl_GlobalInvocationID.xyz);
    if (id.x >= voxel_grid_size_uniform.x || id.y >= voxel_grid_size_uniform.y || id.z >= voxel_grid_size_uniform.z) return;
    
    uint type = get_voxel(id);
    vec3 pos = vec3(id);
    
    if (type == 2u) {
        add_ramp(pos);
        return;
    }
    
    if (type != 1u) return;
    
    // Greedy Logic for ID 1
    ivec3 normal = ivec3(1, 0, 0);
    if (has_face_type(id, normal, 1u)) {
        if (!has_face_type(id - ivec3(0,0,1), normal, 1u)) {
            float len = 1.0;
            for (int k = 1; k < voxel_grid_size_uniform.z - id.z; k++) {
                if (has_face_type(id + ivec3(0,0,k), normal, 1u)) len += 1.0;
                else break;
            }
            add_quad(pos + vec3(1,1,0), vec3(0,0,1), vec3(0,-1,0), len, 1.0, vec3(1,0,0));
        }
    }
    
    normal = ivec3(-1, 0, 0);
    if (has_face_type(id, normal, 1u)) {
        if (!has_face_type(id - ivec3(0,0,1), normal, 1u)) {
            float len = 1.0;
            for (int k = 1; k < voxel_grid_size_uniform.z - id.z; k++) {
                if (has_face_type(id + ivec3(0,0,k), normal, 1u)) len += 1.0;
                else break;
            }
            add_quad(pos, vec3(0,0,1), vec3(0,1,0), len, 1.0, vec3(-1,0,0));
        }
    }
    
    normal = ivec3(0, 1, 0);
    if (has_face_type(id, normal, 1u)) {
        if (!has_face_type(id - ivec3(1,0,0), normal, 1u)) {
            float len = 1.0;
            for (int k = 1; k < voxel_grid_size_uniform.x - id.x; k++) {
                if (has_face_type(id + ivec3(k,0,0), normal, 1u)) len += 1.0;
                else break;
            }
            add_quad(pos + vec3(0,1,1), vec3(1,0,0), vec3(0,0,-1), len, 1.0, vec3(0,1,0));
        }
    }
    
    normal = ivec3(0, -1, 0);
    if (has_face_type(id, normal, 1u)) {
        if (!has_face_type(id - ivec3(1,0,0), normal, 1u)) {
            float len = 1.0;
            for (int k = 1; k < voxel_grid_size_uniform.x - id.x; k++) {
                if (has_face_type(id + ivec3(k,0,0), normal, 1u)) len += 1.0;
                else break;
            }
            add_quad(pos, vec3(1,0,0), vec3(0,0,1), len, 1.0, vec3(0,-1,0));
        }
    }
    
    normal = ivec3(0, 0, 1);
    if (has_face_type(id, normal, 1u)) {
        if (!has_face_type(id - ivec3(1,0,0), normal, 1u)) {
            float len = 1.0;
            for (int k = 1; k < voxel_grid_size_uniform.x - id.x; k++) {
                if (has_face_type(id + ivec3(k,0,0), normal, 1u)) len += 1.0;
                else break;
            }
            add_quad(pos + vec3(0,0,1), vec3(1,0,0), vec3(0,1,0), len, 1.0, vec3(0,0,1));
        }
    }
    
    normal = ivec3(0, 0, -1);
    if (has_face_type(id, normal, 1u)) {
        if (!has_face_type(id - ivec3(1,0,0), normal, 1u)) {
            float len = 1.0;
            for (int k = 1; k < voxel_grid_size_uniform.x - id.x; k++) {
                if (has_face_type(id + ivec3(k,0,0), normal, 1u)) len += 1.0;
                else break;
            }
            add_quad(pos + vec3(0,1,0), vec3(1,0,0), vec3(0,-1,0), len, 1.0, vec3(0,0,-1));
        }
    }
}