#[compute]
#version 450

layout(local_size_x = 4, local_size_y = 4, local_size_z = 4) in;

// Set 1: Per-chunk data
layout(set = 1, binding = 0, std430) restrict buffer OutputVertices {
    float vertices[]; 
} mesh_output;

layout(set = 1, binding = 1, std430) restrict buffer CounterBuffer {
    uvec4 data; // x = triangle_count
} counter;

layout(set = 1, binding = 2, std430) restrict buffer DensityBuffer {
    float values[];
} density_buffer;

layout(set = 1, binding = 3, std430) restrict buffer MaterialBuffer {
    uint values[];
} material_buffer;

// Set 0: Global Lookup Tables (MANDATORY for 4090)
layout(set = 0, binding = 4, std430) readonly buffer LookupTable {
    int edgeTable[256];
    int triTable[4096];
} lookup;

layout(push_constant) uniform PushConstants {
    vec4 chunk_offset;
    float noise_freq;
    float terrain_height;
    float _pad[10];
} params;

const int CHUNK_SIZE = 32;
const float ISO_LEVEL = 0.0;

const int edge_corners[24] = int[](
    0,1, 1,2, 2,3, 3,0,
    4,5, 5,6, 6,7, 7,4,
    0,4, 1,5, 2,6, 3,7
);

float get_density(vec3 p) {
    ivec3 ip = ivec3(round(p));
    ip = clamp(ip, ivec3(0), ivec3(32));
    uint index = uint(ip.x + (ip.y * 33) + (ip.z * 33 * 33));
    return density_buffer.values[index];
}

uint get_material(vec3 p) {
    ivec3 ip = ivec3(round(p));
    ip = clamp(ip, ivec3(0), ivec3(32));
    uint index = uint(ip.x + (ip.y * 33) + (ip.z * 33 * 33));
    return material_buffer.values[index];
}

vec3 get_normal(vec3 pos) {
    float d = 1.0;
    float v_xp = get_density(pos + vec3(d, 0, 0));
    float v_xm = get_density(pos - vec3(d, 0, 0));
    float v_yp = get_density(pos + vec3(0, d, 0));
    float v_ym = get_density(pos - vec3(0, d, 0));
    float v_zp = get_density(pos + vec3(0, 0, d));
    float v_zm = get_density(pos - vec3(0, 0, d));
    return normalize(vec3(v_xp - v_xm, v_yp - v_ym, v_zp - v_zm));
}

vec3 interpolate_vertex(vec3 p1, vec3 p2, float v1, float v2) {
    if (abs(ISO_LEVEL - v1) < 0.00001) return p1;
    if (abs(ISO_LEVEL - v2) < 0.00001) return p2;
    if (abs(v1 - v2) < 0.00001) return p1;
    return p1 + (ISO_LEVEL - v1) * (p2 - p1) / (v2 - v1);
}

void main() {
    uvec3 g_id = gl_GlobalInvocationID.xyz;
    if (g_id.x >= uint(CHUNK_SIZE - 1) || g_id.y >= uint(CHUNK_SIZE - 1) || g_id.z >= uint(CHUNK_SIZE - 1)) return;

    vec3 pos = vec3(g_id);
    vec3 corners[8] = vec3[](
        pos + vec3(0,0,0), pos + vec3(1,0,0), pos + vec3(1,0,1), pos + vec3(0,0,1),
        pos + vec3(0,1,0), pos + vec3(1,1,0), pos + vec3(1,1,1), pos + vec3(0,1,1)
    );

    float densities[8];
    int cubeIndex = 0;
    for(int i = 0; i < 8; i++) {
        densities[i] = get_density(corners[i]);
        if (densities[i] < ISO_LEVEL) cubeIndex |= (1 << i);
    }

    if (lookup.edgeTable[cubeIndex] == 0) return;

    vec3 vertList[12];
    for(int e = 0; e < 12; e++) {
        if ((lookup.edgeTable[cubeIndex] & (1 << e)) != 0) {
            int c1 = edge_corners[e * 2];
            int c2 = edge_corners[e * 2 + 1];
            vertList[e] = interpolate_vertex(corners[c1], corners[c2], densities[c1], densities[c2]);
        }
    }

    uint mat_A = 0u, mat_B = 0u;
    bool found_A = false, found_B = false;
    for (int c = 0; c < 8; c++) {
        if (densities[c] < ISO_LEVEL) {
            uint m = get_material(corners[c]);
            if (!found_A) { mat_A = m; found_A = true; } 
            else if (m != mat_A && !found_B) { mat_B = m; found_B = true; }
        }
    }
    if (!found_B) mat_B = mat_A;

    float encoded_A = float(mat_A) / 255.0;
    float encoded_B = float(mat_B) / 255.0;

    float blendList[12];
    for (int e = 0; e < 12; e++) {
        if ((lookup.edgeTable[cubeIndex] & (1 << e)) != 0) {
            int c1 = edge_corners[e * 2], c2 = edge_corners[e * 2 + 1];
            uint solid_mat = (densities[c1] < ISO_LEVEL) ? get_material(corners[c1]) : get_material(corners[c2]);
            blendList[e] = (solid_mat == mat_A) ? 0.0 : 1.0;
        }
    }

    for (int i = 0; lookup.triTable[cubeIndex * 16 + i] != -1; i += 3) {
        uint tri_idx = atomicAdd(counter.data.x, 1);
        uint base_ptr = tri_idx * 36u;

        // Winding: i, i+2, i+1 for Godot's ForwardWinding (reversed)
        int tri_e[3];
        tri_e[0] = lookup.triTable[cubeIndex * 16 + i];
        tri_e[1] = lookup.triTable[cubeIndex * 16 + i + 2];
        tri_e[2] = lookup.triTable[cubeIndex * 16 + i + 1];

        for (int v = 0; v < 3; v++) {
            int e = tri_e[v];
            vec3 v_pos = vertList[e];
            vec3 v_norm = get_normal(v_pos);
            uint ptr = base_ptr + uint(v) * 12u;
            
            mesh_output.vertices[ptr + 0] = v_pos.x;
            mesh_output.vertices[ptr + 1] = v_pos.y;
            mesh_output.vertices[ptr + 2] = v_pos.z;
            mesh_output.vertices[ptr + 3] = v_norm.x;
            mesh_output.vertices[ptr + 4] = v_norm.y;
            mesh_output.vertices[ptr + 5] = v_norm.z;
            mesh_output.vertices[ptr + 6] = encoded_A;
            mesh_output.vertices[ptr + 7] = encoded_B;
            mesh_output.vertices[ptr + 8] = blendList[e];
            mesh_output.vertices[ptr + 9] = 0.0;
            mesh_output.vertices[ptr + 10] = 0.0;
            mesh_output.vertices[ptr + 11] = 0.0;
        }
    }
}