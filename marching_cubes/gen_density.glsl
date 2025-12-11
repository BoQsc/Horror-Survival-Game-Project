#[compute]
#version 450

// 33x33x33 grid points to cover a 32x32x32 voxel chunk + 1 neighbor edge
layout(local_size_x = 4, local_size_y = 4, local_size_z = 4) in;

// Output: Density values
layout(set = 0, binding = 0, std430) restrict buffer DensityBuffer {
    float values[];
} density_buffer;

layout(push_constant) uniform PushConstants {
    vec4 chunk_offset; // .xyz is position
    float noise_freq;
    float terrain_height;
    float road_spacing;  // Grid spacing for roads (0 = no procedural roads)
    float road_width;    // Width of roads
} params;

// === Noise Functions ===
float hash(vec3 p) {
    p = fract(p * 0.3183099 + .1);
    p *= 17.0;
    return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

float hash2(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
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

// === Procedural Road Network ===
// Returns distance to nearest road and the road's target height
float get_road_info(vec2 pos, float spacing, out float road_height) {
    if (spacing <= 0.0) {
        road_height = 0.0;
        return 1000.0;  // No roads
    }
    
    // Grid-based road network with some variation
    float cell_x = floor(pos.x / spacing);
    float cell_z = floor(pos.y / spacing);
    
    // Position within cell
    float local_x = mod(pos.x, spacing);
    float local_z = mod(pos.y, spacing);
    
    // Road runs along cell edges (X and Z axes)
    float dist_to_x_road = min(local_x, spacing - local_x);  // Distance to vertical road
    float dist_to_z_road = min(local_z, spacing - local_z);  // Distance to horizontal road
    
    float min_dist = min(dist_to_x_road, dist_to_z_road);
    
    // Calculate smoothed road height at this position
    // Sample terrain at multiple grid points and average
    float h1 = noise(vec3(cell_x * spacing, 0.0, cell_z * spacing) * 0.02) * 10.0 + 10.0;
    float h2 = noise(vec3((cell_x + 1.0) * spacing, 0.0, cell_z * spacing) * 0.02) * 10.0 + 10.0;
    float h3 = noise(vec3(cell_x * spacing, 0.0, (cell_z + 1.0) * spacing) * 0.02) * 10.0 + 10.0;
    float h4 = noise(vec3((cell_x + 1.0) * spacing, 0.0, (cell_z + 1.0) * spacing) * 0.02) * 10.0 + 10.0;
    
    // Bilinear interpolation
    float tx = local_x / spacing;
    float tz = local_z / spacing;
    road_height = mix(mix(h1, h2, tx), mix(h3, h4, tx), tz);
    
    return min_dist;
}

float get_density(vec3 pos) {
    vec3 world_pos = pos + params.chunk_offset.xyz;
    
    // Base terrain
    float base_height = params.terrain_height;
    float hill_height = noise(vec3(world_pos.x, 0.0, world_pos.z) * params.noise_freq) * params.terrain_height; 
    float terrain_height = base_height + hill_height;
    float density = world_pos.y - terrain_height;
    
    // Procedural roads
    float road_height;
    float road_dist = get_road_info(world_pos.xz, params.road_spacing, road_height);
    
    if (road_dist < params.road_width) {
        // Inside road area - flatten terrain
        float road_density = world_pos.y - road_height;
        
        // Smooth blend at road edges
        float blend = smoothstep(params.road_width, params.road_width * 0.5, road_dist);
        density = mix(density, road_density, blend);
    }
    
    // Bedrock floor at Y=-20 - creates visible underground surface
    // Below Y=-20 becomes air (positive density) so marching cubes renders a floor
    const float BEDROCK_Y = -20.0;
    if (world_pos.y < BEDROCK_Y) {
        density = 1.0;  // Air below bedrock
    }
    
    return density;
}

void main() {
    uvec3 id = gl_GlobalInvocationID.xyz;
    
    // We need 33 points per axis (0..32)
    if (id.x >= 33 || id.y >= 33 || id.z >= 33) {
        return;
    }

    uint index = id.x + (id.y * 33) + (id.z * 33 * 33);
    vec3 pos = vec3(id);
    
    density_buffer.values[index] = get_density(pos);
}

