#[compute]
#version 450

layout(local_size_x = 4, local_size_y = 4, local_size_z = 4) in;

layout(binding = 0) uniform sampler3D voxel_data;
layout(binding = 7) uniform sampler3D voxel_meta;

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

vec3 rotate_vector(vec3 v, uint r) {
    float nx = v.x;
    float nz = v.z;
    
    if (r == 1u) {
        nx = -v.z;
        nz = v.x;
    } else if (r == 2u) {
        nx = -v.x;
        nz = -v.z;
    } else if (r == 3u) {
        nx = v.z;
        nz = -v.x;
    }
    return vec3(nx, v.y, nz);
}

vec3 rotate_local(vec3 p, uint r) {
    vec3 c = p - vec3(0.5, 0.0, 0.5);
    vec3 rot_c = rotate_vector(c, r);
    return rot_c + vec3(0.5, 0.0, 0.5);
}

void add_triangle(vec3 p0, vec3 p1, vec3 p2, vec3 n0, vec3 n1, vec3 n2, vec2 uv0, vec2 uv1, vec2 uv2) {
    uint v_idx = atomicAdd(vertex_count, 3);
    uint i_idx = atomicAdd(index_count, 3);
    
    uint v_ptr = v_idx * 3;
    
    // CW: p0 -> p2 -> p1 (Preserve original winding logic for compatibility)
    vertices[v_ptr + 0] = p0.x; vertices[v_ptr + 1] = p0.y; vertices[v_ptr + 2] = p0.z;
    vertices[v_ptr + 3] = p2.x; vertices[v_ptr + 4] = p2.y; vertices[v_ptr + 5] = p2.z;
    vertices[v_ptr + 6] = p1.x; vertices[v_ptr + 7] = p1.y; vertices[v_ptr + 8] = p1.z;
    
    // Normals matching the vertex order (p0, p2, p1)
    normals[v_ptr + 0] = n0.x; normals[v_ptr + 1] = n0.y; normals[v_ptr + 2] = n0.z;
    normals[v_ptr + 3] = n2.x; normals[v_ptr + 4] = n2.y; normals[v_ptr + 5] = n2.z;
    normals[v_ptr + 6] = n1.x; normals[v_ptr + 7] = n1.y; normals[v_ptr + 8] = n1.z;
    
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
    
    // CW: p0 -> p3 -> p2 -> p1 (Preserve original layout)
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

void add_ramp(vec3 pos, uint r) {
    // Define local points 0..1
    vec3 l000 = vec3(0,0,0);
    vec3 l100 = vec3(1,0,0);
    vec3 l011 = vec3(0,1,1);
    vec3 l111 = vec3(1,1,1);
    vec3 l001 = vec3(0,0,1);
    vec3 l101 = vec3(1,0,1);
    
    // Rotate them
    vec3 p000 = pos + rotate_local(l000, r);
    vec3 p100 = pos + rotate_local(l100, r);
    vec3 p011 = pos + rotate_local(l011, r);
    vec3 p111 = pos + rotate_local(l111, r);
    vec3 p001 = pos + rotate_local(l001, r);
    vec3 p101 = pos + rotate_local(l101, r);
    
    // Rotate normals
    vec3 slope_n = rotate_vector(normalize(vec3(0, 1, -1)), r);
    vec3 back_n = rotate_vector(vec3(0,0,1), r);
    vec3 bottom_n = rotate_vector(vec3(0,-1,0), r);
    vec3 left_n = rotate_vector(vec3(-1,0,0), r);
    vec3 right_n = rotate_vector(vec3(1,0,0), r);
    
    // Slope Face
    // Origin: p000
    // U: p011 - p000
    // V: p100 - p000
    add_quad(p000, p011 - p000, p100 - p000, 1.0, 1.0, slope_n);
    
    // Back Face
    add_quad(p001, p101 - p001, p011 - p001, 1.0, 1.0, back_n);
    
    // Bottom Face
    add_quad(p000, p100 - p000, p001 - p000, 1.0, 1.0, bottom_n);
    
    // Left Side Triangle
    add_triangle(p000, p001, p011, left_n, left_n, left_n, vec2(0,0), vec2(1,0), vec2(1,1));
    
    // Right Side Triangle
    add_triangle(p100, p111, p101, right_n, right_n, right_n, vec2(0,0), vec2(1,1), vec2(1,0));
}

void add_sphere(vec3 pos) {
    // Simple UV Sphere
    // Radius 0.5, centered at pos + 0.5
    vec3 center = pos + vec3(0.5, 0.5, 0.5);
    float radius = 0.5;
    
    int slices = 16;
    int stacks = 12;
    
    for (int i = 0; i < stacks; i++) {
        float v0 = float(i) / float(stacks);
        float v1 = float(i+1) / float(stacks);
        
        float lat0 = 3.14159 * (-0.5 + v0);
        float z0 = radius * sin(lat0);
        float zr0 = radius * cos(lat0);
        
        float lat1 = 3.14159 * (-0.5 + v1);
        float z1 = radius * sin(lat1);
        float zr1 = radius * cos(lat1);
        
        for (int j = 0; j < slices; j++) {
            float u0 = float(j) / float(slices);
            float u1 = float(j+1) / float(slices);
            
            float lng0 = 2.0 * 3.14159 * u0;
            float x0 = cos(lng0);
            float y0 = sin(lng0);
            
            float lng1 = 2.0 * 3.14159 * u1;
            float x1 = cos(lng1);
            float y1 = sin(lng1);
            
            vec3 p00 = center + vec3(x0 * zr0, z0, y0 * zr0);
            vec3 p10 = center + vec3(x1 * zr0, z0, y1 * zr0);
            vec3 p01 = center + vec3(x0 * zr1, z1, y0 * zr1);
            vec3 p11 = center + vec3(x1 * zr1, z1, y1 * zr1);
            
            // Smooth Normals
            vec3 n00 = normalize(p00 - center);
            vec3 n10 = normalize(p10 - center);
            vec3 n01 = normalize(p01 - center);
            vec3 n11 = normalize(p11 - center);
            
            vec2 uv00 = vec2(u0, v0);
            vec2 uv10 = vec2(u1, v0);
            vec2 uv01 = vec2(u0, v1);
            vec2 uv11 = vec2(u1, v1);
            
            // Fix winding by swapping vertices to CCW (p00 -> p01 -> p11)
            // This ensures the sphere faces are Front-Facing (CCW) and not culled/inverted
            
            // Tri 1: p00 -> p01 -> p11 (CCW Input -> Shader writes p00 -> p11 -> p01 which is CCW relative to p00->p01)
            // Wait, shader writes: v[0]=p0, v[1]=p2, v[2]=p1.
            // If Input is A, B, C. Shader writes A, C, B.
            // We want CCW Output: A, B, C.
            // So Input must be A, C, B.
            // Target Output: p00, p11, p01 (This is CW).
            // Target Output: p00, p01, p11 (This is CCW).
            
            // My previous analysis: p00->p01->p11 is CCW?
            // p00(bl), p01(tl), p11(tr).
            // BL -> TL -> TR.
            // Up, then Right.
            // This is Clockwise.
            
            // So p00 -> p01 -> p11 is CW.
            // p00 -> p11 -> p01 is CCW.
            
            // So we want Output: p00, p11, p01.
            // Shader writes: A, C, B.
            // A=p00. C=p01. B=p11.
            // Shader writes p00, p01, p11 (CW). Bad.
            
            // If A=p00, C=p11, B=p01.
            // Shader writes p00, p11, p01 (CCW). Good.
            // So Input must be p00, p01, p11.
            
            // Current Code: add_triangle(p00, p11, p01...)
            // Input A=p00, B=p11, C=p01.
            // Shader writes A, C, B -> p00, p01, p11 (CW).
            
            // So I need to swap B and C.
            // New Input: p00, p01, p11.
            
            // Tri 1: p00 -> p01 -> p11
            add_triangle(p00, p01, p11, n00, n01, n11, uv00, uv01, uv11);
            
            // Tri 2: p00 -> p11 -> p10
            // Target Output: p00, p11, p10 (CCW? BL -> TR -> BR. UpRight then Down. CCW).
            // So we want Output p00, p11, p10.
            // Shader writes A, C, B.
            // A=p00, C=p11, B=p10.
            // Input: p00, p10, p11.
            
            // Current Code: add_triangle(p00, p10, p11...)
            // Input A=p00, B=p10, C=p11.
            // Shader writes A, C, B -> p00, p11, p10 (CCW).
            
            // Wait. If Tri 2 is ALREADY CCW...
            // Let's re-verify Tri 2.
            // p00(bl), p10(br), p11(tr).
            // p00 -> p11 -> p10.
            // BL -> TR -> BR.
            // Up+Right. Then Down.
            // Encloses Bottom-Right.
            // This is Clockwise!
            
            // So p00 -> p11 -> p10 is CW.
            // p00 -> p10 -> p11 is CCW.
            // BL -> BR -> TR. Right then Up. CCW.
            
            // So we want Output: p00, p10, p11.
            // Shader writes A, C, B.
            // A=p00, C=p10, B=p11.
            // Input: p00, p11, p10.
            
            // Current Code: add_triangle(p00, p10, p11)
            // Input A=p00, B=p10, C=p11.
            // Shader writes A, C, B -> p00, p11, p10 (CW).
            
            // So BOTH are currently CW (Back Facing).
            // I need to swap BOTH.
            
            // New Tri 1 Input: p00, p01, p11.
            // New Tri 2 Input: p00, p11, p10.
            
            add_triangle(p00, p11, p10, n00, n11, n10, uv00, uv11, uv10);
        }
    }
}

void add_stairs(vec3 pos, uint r) {
    // Normals (Local)
    vec3 up = vec3(0,1,0);
    vec3 down = vec3(0,-1,0);
    vec3 front = vec3(0,0,-1); // "Front" faces -Z
    vec3 back = vec3(0,0,1);
    vec3 left = vec3(-1,0,0);
    vec3 right = vec3(1,0,0);
    
    // Rotate Normals
    vec3 r_up = rotate_vector(up, r);
    vec3 r_down = rotate_vector(down, r);
    vec3 r_front = rotate_vector(front, r);
    vec3 r_back = rotate_vector(back, r);
    vec3 r_left = rotate_vector(left, r);
    vec3 r_right = rotate_vector(right, r);
    
    // --- Step 1 (Bottom/Front) ---
    
    // 1. Bottom Step Top (Horizontal)
    // Origin (0, 0.5, 0). U(1,0,0). V(0,0,1) len 0.5.
    // Target Cross: Down. (-Normal). U x V = (0,-1,0).
    vec3 p_st1 = pos + rotate_local(vec3(1, 0.5, 0), r);
    vec3 u_st1 = rotate_vector(vec3(-1,0,0), r);
    vec3 v_st1 = rotate_vector(vec3(0,0,1), r);
    add_quad(p_st1, u_st1, v_st1, 1.0, 0.5, r_up);
    
    // 2. Bottom Step Front (Vertical)
    // Origin (0,0,0). U(1,0,0). V(0,1,0) len 0.5.
    // Target Cross: Back (0,0,1). U x V = (0,0,1).
    vec3 p_sf1 = pos + rotate_local(vec3(1,0,0), r);
    vec3 u_sf1 = rotate_vector(vec3(-1,0,0), r);
    vec3 v_sf1 = rotate_vector(vec3(0,1,0), r);
    add_quad(p_sf1, u_sf1, v_sf1, 1.0, 0.5, r_front);
    
    // --- Step 2 (Top/Back) ---
    
    // 3. Top Step Top (Horizontal)
    // Origin (0, 1.0, 0.5). U(1,0,0). V(0,0,1) len 0.5.
    vec3 p_st2 = pos + rotate_local(vec3(1, 1.0, 0.5), r);
    vec3 u_st2 = rotate_vector(vec3(-1,0,0), r);
    vec3 v_st2 = rotate_vector(vec3(0,0,1), r);
    add_quad(p_st2, u_st2, v_st2, 1.0, 0.5, r_up);
    
    // 4. Top Step Front (Riser) (Vertical)
    // Origin (0, 0.5, 0.5). U(1,0,0). V(0,1,0) len 0.5.
    vec3 p_sf2 = pos + rotate_local(vec3(1, 0.5, 0.5), r);
    vec3 u_sf2 = rotate_vector(vec3(-1,0,0), r);
    vec3 v_sf2 = rotate_vector(vec3(0,1,0), r);
    add_quad(p_sf2, u_sf2, v_sf2, 1.0, 0.5, r_front);
    
    // --- Common ---
    
    // 5. Bottom (Full)
    // Origin (0,0,0). U(1,0,0). V(0,0,1).
    // U x V = (0,-1,0) (Down). Matches Normal.
    vec3 p_bot = pos + rotate_local(vec3(0,0,0), r);
    vec3 u_bot = rotate_vector(vec3(1,0,0), r);
    vec3 v_bot = rotate_vector(vec3(0,0,1), r);
    add_quad(p_bot, u_bot, v_bot, 1.0, 1.0, r_down);
    
    // 6. Back (Full)
    // Origin (0,0,1). U(1,0,0). V(0,1,0).
    // Cross: (0,0,1). Matches Back Normal.
    vec3 p_back = pos + rotate_local(vec3(0,0,1), r);
    vec3 u_back = rotate_vector(vec3(1,0,0), r);
    vec3 v_back = rotate_vector(vec3(0,1,0), r);
    add_quad(p_back, u_back, v_back, 1.0, 1.0, r_back);
    
    // --- Sides ---
    
    // 7. Left Side (X=0)
    // Normal: (-1,0,0). Target Cross: (-1,0,0).
    
    // Left 1 (Front/Bottom)
    // Origin (0,0,0). U(0,0,1). V(0,1,0).
    // Cross: (-1,0,0). Matches Left Normal.
    vec3 p_l1 = pos + rotate_local(vec3(0,0,0), r);
    vec3 u_l1 = rotate_vector(vec3(0,0,1), r);
    vec3 v_l1 = rotate_vector(vec3(0,1,0), r);
    add_quad(p_l1, u_l1, v_l1, 0.5, 0.5, r_left);
    
    // Left 2 (Back/Top)
    // Origin (0,0,0.5). U(0,0,1). V(0,1,0).
    vec3 p_l2 = pos + rotate_local(vec3(0,0,0.5), r);
    vec3 u_l2 = rotate_vector(vec3(0,0,1), r);
    vec3 v_l2 = rotate_vector(vec3(0,1,0), r);
    add_quad(p_l2, u_l2, v_l2, 0.5, 1.0, r_left);
    
    // 8. Right Side (X=1)
    // Normal: (1,0,0). Target Cross: (1,0,0).
    
    // Right 1 (Front/Bottom)
    // Origin (1,0,0.5). U(0,0,-1). V(0,1,0).
    // Cross: (1,0,0). Matches Right Normal.
    vec3 p_r1 = pos + rotate_local(vec3(1,0,0.5), r);
    vec3 u_r1 = rotate_vector(vec3(0,0,-1), r);
    vec3 v_r1 = rotate_vector(vec3(0,1,0), r);
    add_quad(p_r1, u_r1, v_r1, 0.5, 0.5, r_right);
    
    // Right 2 (Back/Top)
    // Origin (1,0,1.0). U(0,0,-1). V(0,1,0).
    vec3 p_r2 = pos + rotate_local(vec3(1,0,1.0), r);
    vec3 u_r2 = rotate_vector(vec3(0,0,-1), r);
    vec3 v_r2 = rotate_vector(vec3(0,1,0), r);
    add_quad(p_r2, u_r2, v_r2, 0.5, 1.0, r_right);
}

void main() {
    ivec3 id = ivec3(gl_GlobalInvocationID.xyz);
    if (id.x >= voxel_grid_size_uniform.x || id.y >= voxel_grid_size_uniform.y || id.z >= voxel_grid_size_uniform.z) return;
    
    uint type = get_voxel(id);
    vec3 pos = vec3(id);
    
    if (type == 2u) {
        uint meta = uint(round(texelFetch(voxel_meta, id, 0).r));
        add_ramp(pos, meta);
        return;
    }
    
    if (type == 3u) {
        add_sphere(pos);
        return;
    }
    
    if (type == 4u) {
        uint meta = uint(round(texelFetch(voxel_meta, id, 0).r));
        add_stairs(pos, meta);
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