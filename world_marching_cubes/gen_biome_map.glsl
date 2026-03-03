#[compute]
#version 450

// Generates a 2D biome map using the SAME fbm() noise as gen_density.glsl and terrain.gdshader.
// This ensures the minimap matches the in-game terrain biome rendering exactly.
// Dispatch: ceil(map_size/16) x ceil(map_size/16) x 1 workgroups

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// Output: biome IDs (one byte per pixel, packed as uint)
layout(set = 0, binding = 0, std430) restrict buffer BiomeBuffer {
    uint values[];
} biome_buffer;

layout(push_constant) uniform PushConstants {
    float map_size;       // e.g. 2048
    float map_half;       // map_size / 2
    float pad0;
    float pad1;
} params;

// === 2D Simplex Noise (identical to gen_density.glsl and terrain.gdshader) ===
vec2 hash2d(vec2 p) {
    p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
    return -1.0 + 2.0 * fract(sin(p) * 43758.5453123);
}

float noise2d(vec2 p) {
    const float K1 = 0.366025404;
    const float K2 = 0.211324865;

    vec2 i = floor(p + (p.x + p.y) * K1);
    vec2 a = p - i + (i.x + i.y) * K2;
    float m = step(a.y, a.x);
    vec2 o = vec2(m, 1.0 - m);
    vec2 b = a - o + K2;
    vec2 c = a - 1.0 + 2.0 * K2;

    vec3 h = max(0.5 - vec3(dot(a, a), dot(b, b), dot(c, c)), 0.0);
    vec3 n = h * h * h * h * vec3(dot(a, hash2d(i + 0.0)), dot(b, hash2d(i + o)), dot(c, hash2d(i + 1.0)));

    return dot(n, vec3(70.0));
}

float fbm(vec2 p) {
    float f = 0.0;
    float w = 0.5;
    for (int i = 0; i < 3; i++) {
        f += w * noise2d(p);
        p *= 2.0;
        w *= 0.5;
    }
    return f;
}

void main() {
    uint px = gl_GlobalInvocationID.x;
    uint py = gl_GlobalInvocationID.y;
    uint map_size_u = uint(params.map_size);

    if (px >= map_size_u || py >= map_size_u) return;

    // World coordinates (matches world_map_generator.gd: wx = x - half, wz = z - half)
    float wx = float(px) - params.map_half;
    float wz = float(py) - params.map_half;

    // Evaluate the SAME fbm as gen_density.glsl line 347 and terrain.gdshader line 199
    float biome_val = fbm(vec2(wx, wz) * 0.002);

    // Apply same thresholds as gen_density.glsl lines 349-353
    uint biome_id = 0u;  // Grass
    if (biome_val < -0.2) biome_id = 3u;       // Sand
    else if (biome_val > 0.6) biome_id = 5u;    // Snow
    else if (biome_val > 0.2) biome_id = 4u;    // Gravel

    // Pack into byte array (4 bytes per uint)
    uint index = py * map_size_u + px;
    uint word_index = index / 4u;
    uint byte_offset = index % 4u;

    // Atomic OR to write one byte into the packed uint
    uint shift = byte_offset * 8u;
    atomicOr(biome_buffer.values[word_index], biome_id << shift);
}
