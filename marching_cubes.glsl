#[compute]
#version 450

// We dispatch 1 thread per voxel.
// 8x8x8 threads per workgroup is a standard optimization.
layout(local_size_x = 8, local_size_y = 8, local_size_z = 8) in;

// BINDINGS
// -----------------------------------------------------------
// Binding 0: The output vertex buffer (std430 ensures tight packing)
layout(set = 0, binding = 0, std430) restrict buffer OutputVertices {
    float vertices[]; 
} mesh_output;

// Binding 1: An atomic counter so threads know where to write
layout(set = 0, binding = 1, std430) restrict buffer CounterBuffer {
    uint triangle_count;
} counter;

// SETTINGS
const int CHUNK_SIZE = 32;
const float ISO_LEVEL = 0.0;

// --- INCLUDES ---

// Marching Cubes: import const int edgeTable[256] and const int triTable[4096]
#include "res://marching_cubes_lookup_table.glsl"

// HELPER FUNCTIONS
// -----------------------------------------------------------

// Simple noise function (Placeholder for 3D Simplex/Perlin)
float get_density(vec3 pos) {
    // A simple sphere density function: radius 15 at center of chunk
    float radius = 15.0;
    vec3 center = vec3(float(CHUNK_SIZE) / 2.0);
    return radius - distance(pos, center);
    
    // In production, sample a 3D texture or improved noise here
}

vec3 interpolate_vertex(vec3 p1, vec3 p2, float v1, float v2) {
    // Linear Interpolation formula
    return p1 + (ISO_LEVEL - v1) * (p2 - p1) / (v2 - v1);
}

// MAIN EXECUTION
// -----------------------------------------------------------
void main() {
    // Current Voxel Position
    uvec3 id = gl_GlobalInvocationID.xyz;
    
    // Boundary check
    if (id.x >= CHUNK_SIZE - 1 || id.y >= CHUNK_SIZE - 1 || id.z >= CHUNK_SIZE - 1) {
        return;
    }

    vec3 pos = vec3(id);

    // 1. Sample Corners
    // -------------------------------------
    // Corners of the cube relative to 'pos'
    vec3 corners[8] = vec3[](
        pos + vec3(0,0,0), pos + vec3(1,0,0), pos + vec3(1,0,1), pos + vec3(0,0,1),
        pos + vec3(0,1,0), pos + vec3(1,1,0), pos + vec3(1,1,1), pos + vec3(0,1,1)
    );

    float densities[8];
    for(int i = 0; i < 8; i++) {
        densities[i] = get_density(corners[i]);
    }

    // 2. Determine Cube Index
    // -------------------------------------
    int cubeIndex = 0;
    if (densities[0] < ISO_LEVEL) cubeIndex |= 1;
    if (densities[1] < ISO_LEVEL) cubeIndex |= 2;
    if (densities[2] < ISO_LEVEL) cubeIndex |= 4;
    if (densities[3] < ISO_LEVEL) cubeIndex |= 8;
    if (densities[4] < ISO_LEVEL) cubeIndex |= 16;
    if (densities[5] < ISO_LEVEL) cubeIndex |= 32;
    if (densities[6] < ISO_LEVEL) cubeIndex |= 64;
    if (densities[7] < ISO_LEVEL) cubeIndex |= 128;

    // If cube is entirely inside or outside, return early
    if (edgeTable[cubeIndex] == 0) return;

    // 3. Calculate Intersection Vertices
    // -------------------------------------
    vec3 vertList[12];
    
    // Edges are defined by pairs of corners. 
    // This mapping matches Paul Bourke's convention.
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

    // 4. Generate Triangles
    // -------------------------------------
    // Iterate triTable to find which vertices make triangles
    for (int i = 0; triTable[cubeIndex * 16 + i] != -1; i += 3) {
        
        // Atomic Add to reserve space in the buffer safely
        uint idx = atomicAdd(counter.triangle_count, 1);
        
        // Calculate the starting index in the float array
        // Each triangle has 3 vertices. Each vertex has 3 floats (x,y,z).
        // Total = 9 floats per triangle.
        uint start_ptr = idx * 9;

        vec3 v1 = vertList[triTable[cubeIndex * 16 + i]];
        vec3 v2 = vertList[triTable[cubeIndex * 16 + i + 1]];
        vec3 v3 = vertList[triTable[cubeIndex * 16 + i + 2]];

        // Write vertices
        mesh_output.vertices[start_ptr + 0] = v1.x;
        mesh_output.vertices[start_ptr + 1] = v1.y;
        mesh_output.vertices[start_ptr + 2] = v1.z;
        
        mesh_output.vertices[start_ptr + 3] = v2.x;
        mesh_output.vertices[start_ptr + 4] = v2.y;
        mesh_output.vertices[start_ptr + 5] = v2.z;
        
        mesh_output.vertices[start_ptr + 6] = v3.x;
        mesh_output.vertices[start_ptr + 7] = v3.y;
        mesh_output.vertices[start_ptr + 8] = v3.z;
    }
}