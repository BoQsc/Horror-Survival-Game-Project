#[compute]
#version 450

// We dispatch 1 thread per voxel.
layout(local_size_x = 8, local_size_y = 8, local_size_z = 8) in;

// BINDINGS
layout(set = 0, binding = 0, std430) restrict buffer OutputVertices {
    float vertices[]; 
} mesh_output;

layout(set = 0, binding = 1, std430) restrict buffer CounterBuffer {
    uint triangle_count;
} counter;

// New Binding: Input Density Map
layout(set = 0, binding = 2, std430) restrict buffer DensityBuffer {
    float values[];
} density_buffer;

// New Binding: Input Material Map
layout(set = 0, binding = 3, std430) restrict buffer MaterialBuffer {
    uint values[];
} material_buffer;

layout(push_constant) uniform PushConstants {
    vec4 chunk_offset; // .xyz is position
    float noise_freq;
    float terrain_height;
} params;

const int CHUNK_SIZE = 32;
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

// Convert material ID to RGB color for vertex color
// R channel encodes material ID (0-255), G=1 marks valid material
// Material IDs: 0=Grass, 1=Stone, 2=Ore, 3=Sand, 4=Gravel, 5=Snow, 6=Road, 100+=Player
vec3 material_to_color(uint mat_id) {
    // Encode material ID in R channel (normalized to 0-1)
    // Fragment shader decodes: int id = int(round(color.r * 255.0))
    float encoded_id = float(mat_id) / 255.0;
    return vec3(encoded_id, 1.0, 0.0);  // G=1 marks valid, B unused
}

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

    for (int i = 0; triTable[cubeIndex * 16 + i] != -1; i += 3) {
        
        uint idx = atomicAdd(counter.triangle_count, 1);
        uint start_ptr = idx * 27;  // 9 floats per vertex (pos + normal + color) 

        vec3 v1 = vertList[triTable[cubeIndex * 16 + i]];
        vec3 v2 = vertList[triTable[cubeIndex * 16 + i + 1]];
        vec3 v3 = vertList[triTable[cubeIndex * 16 + i + 2]];

        // Get material color from center of cube
        uint mat_id = get_material_from_buffer(pos + vec3(0.5));
        vec3 mat_color = material_to_color(mat_id);
        
        // Vertex 1
        vec3 n1 = get_normal(v1);
        mesh_output.vertices[start_ptr + 0] = v1.x;
        mesh_output.vertices[start_ptr + 1] = v1.y;
        mesh_output.vertices[start_ptr + 2] = v1.z;
        mesh_output.vertices[start_ptr + 3] = n1.x;
        mesh_output.vertices[start_ptr + 4] = n1.y;
        mesh_output.vertices[start_ptr + 5] = n1.z;
        mesh_output.vertices[start_ptr + 6] = mat_color.r;
        mesh_output.vertices[start_ptr + 7] = mat_color.g;
        mesh_output.vertices[start_ptr + 8] = mat_color.b;
        
        // Vertex 3 (note: order is 1,3,2 for winding)
        vec3 n3 = get_normal(v3);
        mesh_output.vertices[start_ptr + 9] = v3.x;
        mesh_output.vertices[start_ptr + 10] = v3.y;
        mesh_output.vertices[start_ptr + 11] = v3.z;
        mesh_output.vertices[start_ptr + 12] = n3.x;
        mesh_output.vertices[start_ptr + 13] = n3.y;
        mesh_output.vertices[start_ptr + 14] = n3.z;
        mesh_output.vertices[start_ptr + 15] = mat_color.r;
        mesh_output.vertices[start_ptr + 16] = mat_color.g;
        mesh_output.vertices[start_ptr + 17] = mat_color.b;
        
        // Vertex 2
        vec3 n2 = get_normal(v2);
        mesh_output.vertices[start_ptr + 18] = v2.x;
        mesh_output.vertices[start_ptr + 19] = v2.y;
        mesh_output.vertices[start_ptr + 20] = v2.z;
        mesh_output.vertices[start_ptr + 21] = n2.x;
        mesh_output.vertices[start_ptr + 22] = n2.y;
        mesh_output.vertices[start_ptr + 23] = n2.z;
        mesh_output.vertices[start_ptr + 24] = mat_color.r;
        mesh_output.vertices[start_ptr + 25] = mat_color.g;
        mesh_output.vertices[start_ptr + 26] = mat_color.b;
    }
}