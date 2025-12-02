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

layout(push_constant) uniform PushConstants {
    vec4 chunk_offset; // .xyz is position, .w is padding (but we send 0.0)
    float noise_freq;
    float terrain_height;
} params;

const int CHUNK_SIZE = 32;
const float ISO_LEVEL = 0.0;

#include "res://marching_cubes_lookup_table.glsl"

// --- NOISE ---
float hash(vec3 p) {
    p = fract(p * 0.3183099 + .1);
    p *= 17.0;
    return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

float noise(vec3 x) {
    vec3 i = floor(x);
    vec3 f = fract(x);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(mix( hash(i + vec3(0,0,0)), hash(i + vec3(1,0,0)), f.x),
                   mix( hash(i + vec3(0,1,0)), hash(i + vec3(1,1,0)), f.x), f.y),
               mix(mix( hash(i + vec3(0,0,1)), hash(i + vec3(1,0,1)), f.x),
                   mix( hash(i + vec3(0,1,1)), hash(i + vec3(1,1,1)), f.x), f.y), f.z);
}

// --- DENSITY ---
float get_density(vec3 pos) {
    vec3 world_pos = pos + params.chunk_offset.xyz;

    float base_height = params.terrain_height;
    // Use 2D noise for heightmap (ignore Y variation in noise lookup)
    // We use a small Y offset in the noise lookup just to ensure it's not 0 if that matters, 
    // but effectively we scan a 2D plane.
    float hill_height = noise(vec3(world_pos.x, 0.0, world_pos.z) * params.noise_freq) * params.terrain_height; 
    
    float terrain_height = base_height + hill_height;
    return world_pos.y - terrain_height;
}

vec3 get_normal(vec3 pos) {
    float d = 0.01;
    float gx = get_density(pos + vec3(d, 0, 0)) - get_density(pos - vec3(d, 0, 0));
    float gy = get_density(pos + vec3(0, d, 0)) - get_density(pos - vec3(0, d, 0));
    float gz = get_density(pos + vec3(0, 0, d)) - get_density(pos - vec3(0, 0, d));
    return normalize(vec3(gx, gy, gz));
}

vec3 interpolate_vertex(vec3 p1, vec3 p2, float v1, float v2) {
    if (abs(ISO_LEVEL - v1) < 0.00001) return p1;
    if (abs(ISO_LEVEL - v2) < 0.00001) return p2;
    if (abs(v1 - v2) < 0.00001) return p1;
    return p1 + (ISO_LEVEL - v1) * (p2 - p1) / (v2 - v1);
}

void main() {
    uvec3 id = gl_GlobalInvocationID.xyz;
    
    if (id.x >= CHUNK_SIZE - 1 || id.y >= CHUNK_SIZE - 1 || id.z >= CHUNK_SIZE - 1) {
        return;
    }

    vec3 pos = vec3(id);

    vec3 corners[8] = vec3[](
        pos + vec3(0,0,0), pos + vec3(1,0,0), pos + vec3(1,0,1), pos + vec3(0,0,1),
        pos + vec3(0,1,0), pos + vec3(1,1,0), pos + vec3(1,1,1), pos + vec3(0,1,1)
    );

    float densities[8];
    for(int i = 0; i < 8; i++) {
        densities[i] = get_density(corners[i]);
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
        // 3 vertices per triangle * 6 floats per vertex = 18 floats per triangle
        uint start_ptr = idx * 18; 

        vec3 v1 = vertList[triTable[cubeIndex * 16 + i]];
        vec3 v2 = vertList[triTable[cubeIndex * 16 + i + 1]];
        vec3 v3 = vertList[triTable[cubeIndex * 16 + i + 2]];

        // --- FIXED WINDING ORDER (v1 -> v3 -> v2) ---
        
        // Vertex 1
        vec3 n1 = get_normal(v1);
        mesh_output.vertices[start_ptr + 0] = v1.x;
        mesh_output.vertices[start_ptr + 1] = v1.y;
        mesh_output.vertices[start_ptr + 2] = v1.z;
        mesh_output.vertices[start_ptr + 3] = n1.x;
        mesh_output.vertices[start_ptr + 4] = n1.y;
        mesh_output.vertices[start_ptr + 5] = n1.z;
        
        // Vertex 3 (Swapped)
        vec3 n3 = get_normal(v3);
        mesh_output.vertices[start_ptr + 6] = v3.x;
        mesh_output.vertices[start_ptr + 7] = v3.y;
        mesh_output.vertices[start_ptr + 8] = v3.z;
        mesh_output.vertices[start_ptr + 9] = n3.x;
        mesh_output.vertices[start_ptr + 10] = n3.y;
        mesh_output.vertices[start_ptr + 11] = n3.z;
        
        // Vertex 2 (Swapped)
        vec3 n2 = get_normal(v2);
        mesh_output.vertices[start_ptr + 12] = v2.x;
        mesh_output.vertices[start_ptr + 13] = v2.y;
        mesh_output.vertices[start_ptr + 14] = v2.z;
        mesh_output.vertices[start_ptr + 15] = n2.x;
        mesh_output.vertices[start_ptr + 16] = n2.y;
        mesh_output.vertices[start_ptr + 17] = n2.z;
    }
}