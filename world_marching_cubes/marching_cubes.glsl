#[compute]
#version 450

// We dispatch 1 thread per voxel.
layout(local_size_x = 8, local_size_y = 8, local_size_z = 8) in;

// BINDINGS
layout(set = 0, binding = 0, std430) restrict buffer OutputVertices {
    uint words[];
} mesh_output;

layout(set = 0, binding = 1, std430) restrict buffer CounterBuffer {
    uint triangle_count;
    uint output_format_magic;
    uint vertex_count;
} counter;

// New Binding: Input Density Map
layout(set = 0, binding = 2, std430) restrict buffer DensityBuffer {
    float values[];
} density_buffer;

// New Binding: Input Material Map
layout(set = 0, binding = 3, std430) restrict buffer MaterialBuffer {
    uint values[];
} material_buffer;

layout(set = 0, binding = 4, std430) restrict buffer OutputIndices {
    uint values[];
} index_output;

layout(push_constant) uniform PushConstants {
    vec4 chunk_offset; // .xyz is position
    float noise_freq;
    float terrain_height;
} params;

const int CHUNK_SIZE = 32;
const uint PACKED_VERTEX_WORDS = 6u;
const uint PACKED_INDEXED_OUTPUT_MAGIC = 0x58444950u; // "PIDX"
const float ISO_LEVEL = 0.0;

#include "res://world_marching_cubes/marching_cubes_lookup_table.glslinc"

float get_density_from_buffer(vec3 p) {
    // p is local coordinates (0..32)
    // The buffer is 33x33x33
    int x = int(round(p.x));
    int y = int(round(p.y));
    int z = int(round(p.z));
    
    // Clamp to safe bounds
    x = clamp(x, 0, 32);
    y = clamp(y, 0, 32);
    z = clamp(z, 0, 32);
    
    uint index = x + (y * 33) + (z * 33 * 33);
    return density_buffer.values[index];
}

uint get_material_from_buffer(vec3 p) {
    int x = int(round(p.x));
    int y = int(round(p.y));
    int z = int(round(p.z));
    x = clamp(x, 0, 32);
    y = clamp(y, 0, 32);
    z = clamp(z, 0, 32);
    uint index = x + (y * 33) + (z * 33 * 33);
    return material_buffer.values[index];
}

// Dual-material encoding for vertex color:
// R = mat_A / 255.0 (primary material ID)
// G = mat_B / 255.0 (secondary material ID)
// B = blend factor (0.0 = 100% mat_A, 1.0 = 100% mat_B)
// Material IDs: 0=Grass, 1=Stone, 2=Ore, 3=Sand, 4=Gravel, 5=Snow, 6=Road, 9=Granite, 100+=Player

uint pack_material_payload(uint mat_a, uint mat_b, float blend) {
    uint blend_byte = (blend > 0.5) ? 255u : 0u;
    return (mat_a & 0xFFu) | ((mat_b & 0xFFu) << 8u) | (blend_byte << 16u);
}

void write_packed_vertex(uint base_word, vec3 pos, vec3 normal, uint mat_a, uint mat_b, float blend) {
    mesh_output.words[base_word + 0u] = floatBitsToUint(pos.x);
    mesh_output.words[base_word + 1u] = floatBitsToUint(pos.y);
    mesh_output.words[base_word + 2u] = floatBitsToUint(pos.z);
    mesh_output.words[base_word + 3u] = packHalf2x16(normal.xy);
    mesh_output.words[base_word + 4u] = packHalf2x16(vec2(normal.z, 0.0));
    mesh_output.words[base_word + 5u] = pack_material_payload(mat_a, mat_b, blend);
}

// Edge-to-corner mapping (standard MC edge numbering)
// Each edge connects two corners: edge_corners[edge*2] and edge_corners[edge*2+1]
const int edge_corners[24] = int[](
    0,1, 1,2, 2,3, 3,0,   // edges 0-3
    4,5, 5,6, 6,7, 7,4,   // edges 4-7
    0,4, 1,5, 2,6, 3,7    // edges 8-11
);

vec3 get_normal(vec3 pos) {
    // Calculate gradient from the buffer
    // We can't sample arbitrarily small delta 'd' because we are on a grid.
    // We must sample neighbors.
    
    vec3 n;
    float d = 1.0;
    
    float v_xp = get_density_from_buffer(pos + vec3(d, 0, 0));
    float v_xm = get_density_from_buffer(pos - vec3(d, 0, 0));
    float v_yp = get_density_from_buffer(pos + vec3(0, d, 0));
    float v_ym = get_density_from_buffer(pos - vec3(0, d, 0));
    float v_zp = get_density_from_buffer(pos + vec3(0, 0, d));
    float v_zm = get_density_from_buffer(pos - vec3(0, 0, d));
    
    n.x = v_xp - v_xm;
    n.y = v_yp - v_ym;
    n.z = v_zp - v_zm;
    
    return normalize(n);
}

vec3 interpolate_vertex(vec3 p1, vec3 p2, float v1, float v2) {
    if (abs(ISO_LEVEL - v1) < 0.00001) return p1;
    if (abs(ISO_LEVEL - v2) < 0.00001) return p2;
    if (abs(v1 - v2) < 0.00001) return p1;
    return p1 + (ISO_LEVEL - v1) * (p2 - p1) / (v2 - v1);
}

void main() {
    uvec3 id = gl_GlobalInvocationID.xyz;

    if (id.x == 0u && id.y == 0u && id.z == 0u) {
        counter.output_format_magic = PACKED_INDEXED_OUTPUT_MAGIC;
    }
    
    if (id.x >= uint(CHUNK_SIZE) - 1u || id.y >= uint(CHUNK_SIZE) - 1u || id.z >= uint(CHUNK_SIZE) - 1u) {
        return;
    }

    vec3 pos = vec3(id);

    // Sample 8 corners from the buffer
    vec3 corners[8] = vec3[](
        pos + vec3(0,0,0), pos + vec3(1,0,0), pos + vec3(1,0,1), pos + vec3(0,0,1),
        pos + vec3(0,1,0), pos + vec3(1,1,0), pos + vec3(1,1,1), pos + vec3(0,1,1)
    );

    float densities[8];
    for(int i = 0; i < 8; i++) {
        densities[i] = get_density_from_buffer(corners[i]);
    }

    int cubeIndex = 0;
    if (densities[0] < ISO_LEVEL) cubeIndex |= 1;
    if (densities[1] < ISO_LEVEL) cubeIndex |= 2;
    if (densities[2] < ISO_LEVEL) cubeIndex |= 4;
    if (densities[3] < ISO_LEVEL) cubeIndex |= 8;
    if (densities[4] < ISO_LEVEL) cubeIndex |= 16;
    if (densities[5] < ISO_LEVEL) cubeIndex |= 32;
    if (densities[6] < ISO_LEVEL) cubeIndex |= 64;
    if (densities[7] < ISO_LEVEL) cubeIndex |= 128;

    if (edgeTable[cubeIndex] == 0) return;

    vec3 vertList[12];
    
    if ((edgeTable[cubeIndex] & 1) != 0)    vertList[0] = interpolate_vertex(corners[0], corners[1], densities[0], densities[1]);
    if ((edgeTable[cubeIndex] & 2) != 0)    vertList[1] = interpolate_vertex(corners[1], corners[2], densities[1], densities[2]);
    if ((edgeTable[cubeIndex] & 4) != 0)    vertList[2] = interpolate_vertex(corners[2], corners[3], densities[2], densities[3]);
    if ((edgeTable[cubeIndex] & 8) != 0)    vertList[3] = interpolate_vertex(corners[3], corners[0], densities[3], densities[0]);
    if ((edgeTable[cubeIndex] & 16) != 0)   vertList[4] = interpolate_vertex(corners[4], corners[5], densities[4], densities[5]);
    if ((edgeTable[cubeIndex] & 32) != 0)   vertList[5] = interpolate_vertex(corners[5], corners[6], densities[5], densities[6]);
    if ((edgeTable[cubeIndex] & 64) != 0)   vertList[6] = interpolate_vertex(corners[6], corners[7], densities[6], densities[7]);
    if ((edgeTable[cubeIndex] & 128) != 0)  vertList[7] = interpolate_vertex(corners[7], corners[4], densities[7], densities[4]);
    if ((edgeTable[cubeIndex] & 256) != 0)  vertList[8] = interpolate_vertex(corners[0], corners[4], densities[0], densities[4]);
    if ((edgeTable[cubeIndex] & 512) != 0)  vertList[9] = interpolate_vertex(corners[1], corners[5], densities[1], densities[5]);
    if ((edgeTable[cubeIndex] & 1024) != 0) vertList[10] = interpolate_vertex(corners[2], corners[6], densities[2], densities[6]);
    if ((edgeTable[cubeIndex] & 2048) != 0) vertList[11] = interpolate_vertex(corners[3], corners[7], densities[3], densities[7]);

    vec3 normalList[12];
    for (int e = 0; e < 12; e++) {
        if ((edgeTable[cubeIndex] & (1 << e)) != 0) {
            normalList[e] = get_normal(vertList[e]);
        }
    }

    // === DUAL-MATERIAL DETECTION ===
    // Find the two materials present among solid corners in this cube.
    // mat_A = primary (first solid corner found)
    // mat_B = secondary (first DIFFERENT material found, or same as mat_A)
    uint mat_A = 0u;
    uint mat_B = 0u;
    bool found_A = false;
    bool found_B = false;
    for (int c = 0; c < 8; c++) {
        if (densities[c] < ISO_LEVEL) {
            uint m = get_material_from_buffer(corners[c]);
            if (!found_A) {
                mat_A = m;
                found_A = true;
            } else if (m != mat_A && !found_B) {
                mat_B = m;
                found_B = true;
            }
        }
    }
    if (!found_B) mat_B = mat_A;  // Only one material in this cube

    // === PER-VERTEX BLEND FACTORS ===
    // For each edge vertex, check which material is on the solid side.
    // blend = 0.0 if solid corner has mat_A, blend = 1.0 if mat_B.
    float blendList[12];
    for (int e = 0; e < 12; e++) {
        if ((edgeTable[cubeIndex] & (1 << e)) != 0) {
            int c1 = edge_corners[e * 2];
            int c2 = edge_corners[e * 2 + 1];
            // Find the solid corner on this edge
            int solid_c = (densities[c1] < ISO_LEVEL) ? c1 : c2;
            uint solid_mat = get_material_from_buffer(corners[solid_c]);
            blendList[e] = (solid_mat == mat_A) ? 0.0 : 1.0;
        }
    }

    uint vertexIndexList[12];
    for (int e = 0; e < 12; e++) {
        if ((edgeTable[cubeIndex] & (1 << e)) != 0) {
            uint vertex_idx = atomicAdd(counter.vertex_count, 1u);
            vertexIndexList[e] = vertex_idx;
            write_packed_vertex(vertex_idx * PACKED_VERTEX_WORDS, vertList[e], normalList[e], mat_A, mat_B, blendList[e]);
        }
    }

    for (int i = 0; triTable[cubeIndex * 16 + i] != -1; i += 3) {
        
        uint idx = atomicAdd(counter.triangle_count, 1);
        uint start_ptr = idx * 3u;

        int e1 = triTable[cubeIndex * 16 + i];
        int e2 = triTable[cubeIndex * 16 + i + 1];
        int e3 = triTable[cubeIndex * 16 + i + 2];

        index_output.values[start_ptr + 0u] = vertexIndexList[e1];
        // Vertex 3 (note: order is 1,3,2 for winding)
        index_output.values[start_ptr + 1u] = vertexIndexList[e3];
        // Vertex 2
        index_output.values[start_ptr + 2u] = vertexIndexList[e2];
    }
}
