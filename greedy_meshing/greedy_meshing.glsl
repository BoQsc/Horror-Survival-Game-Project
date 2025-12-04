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
    add_triangle(p000, p001, p011, left_n, vec2(0,0), vec2(1,0), vec2(1,1));
    
    // Right Side Triangle
    add_triangle(p100, p111, p101, right_n, vec2(0,0), vec2(1,1), vec2(1,0));
}

void add_sphere(vec3 pos) {
    // Simple UV Sphere
    // Radius 0.5, centered at pos + 0.5
    vec3 center = pos + vec3(0.5, 0.5, 0.5);
    float radius = 0.5;
    
    int slices = 8; // Longitude
    int stacks = 8; // Latitude
    
    for (int i = 0; i < stacks; i++) {
        float lat0 = 3.14159 * (-0.5 + float(i) / float(stacks));
        float z0 = radius * sin(lat0);
        float zr0 = radius * cos(lat0);
        
        float lat1 = 3.14159 * (-0.5 + float(i+1) / float(stacks));
        float z1 = radius * sin(lat1);
        float zr1 = radius * cos(lat1);
        
        for (int j = 0; j < slices; j++) {
            float lng0 = 2.0 * 3.14159 * float(j) / float(slices);
            float x0 = cos(lng0);
            float y0 = sin(lng0);
            
            float lng1 = 2.0 * 3.14159 * float(j+1) / float(slices);
            float x1 = cos(lng1);
            float y1 = sin(lng1);
            
            vec3 p00 = center + vec3(x0 * zr0, z0, y0 * zr0);
            vec3 p10 = center + vec3(x1 * zr0, z0, y1 * zr0);
            vec3 p01 = center + vec3(x0 * zr1, z1, y0 * zr1);
            vec3 p11 = center + vec3(x1 * zr1, z1, y1 * zr1);
            
            // Normals (Approximate - from center)
            vec3 n = normalize(p00 - center); // Just using one normal for the face for flat shading look or per-vertex if we cared
            
            // Add 2 triangles (Quad)
            // Triangle 1: p00 -> p01 -> p11
            vec3 n1 = normalize(cross(p01 - p00, p11 - p00));
             // Fix orientation if needed.
             // p00 (bottom left), p01 (top left), p11 (top right), p10 (bottom right)
             // p00 -> p01 -> p11 (CCW from outside? Let's check cross prod)
             // (0,1) - (0,0) = (0,1). (1,1) - (0,0) = (1,1). cross((0,1), (1,1)) = -k (Inside).
             // So CW: p00 -> p11 -> p01
            
            // Wait, standard grid:
            // lat increasing goes UP (+Y in my local math? No, +Y is Up in Godot).
            // I used z0 = radius * sin(lat). So Z is UP?
            // In Godot Y is Up.
            // Let's map: lat -> Y axis. lng -> X/Z plane.
            // My code: vec3(x*zr, z, y*zr). So Y is z0. Correct.
            
            // Quad p00(bl), p10(br), p11(tr), p01(tl)
            
            // Tri 1: p00, p11, p01
            add_triangle(p00, p11, p01, normalize(p00 - center), vec2(0,0), vec2(1,1), vec2(0,1));
            
            // Tri 2: p00, p10, p11
            add_triangle(p00, p10, p11, normalize(p00 - center), vec2(0,0), vec2(1,0), vec2(1,1));
        }
    }
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