shader_type spatial;

uniform sampler2D texture_grass : source_color, filter_linear_mipmap;
uniform sampler2D texture_rock : source_color, filter_linear_mipmap;   // For cliff faces only
uniform sampler2D texture_stone : source_color, filter_linear_mipmap;  // For underground/gravel/ore
uniform sampler2D texture_sand : source_color, filter_linear_mipmap;
uniform sampler2D texture_snow : source_color, filter_linear_mipmap;
uniform sampler2D texture_road : source_color, filter_linear_mipmap;  // Asphalt texture

uniform float uv_scale = 0.5;
uniform float biome_scale = 0.002; // Smaller = larger biomes
uniform float global_snow_amount : hint_range(0.0, 1.0) = 0.0;

// Road mask system - samples road_mask texture based on world position
// filter_linear for smooth edges (requires higher resolution mask)
uniform sampler2D road_mask : hint_default_black, filter_linear, repeat_disable;
uniform vec2 road_mask_offset = vec2(0.0);  // World offset for mask
uniform float road_mask_scale = 0.0005;      // World units to UV (2000m coverage)

// Procedural road texture toggle (matches density shader roads)
uniform bool procedural_road_enabled = true;
uniform float procedural_road_spacing = 100.0;
uniform float procedural_road_width = 8.0;

// Road edge blending - soft gradient transition from road to terrain
uniform bool road_edge_blend_enabled = true;
uniform float road_edge_blend_width = 0.5;  // Width of the blend zone in world units

// Terrain parameters for per-pixel material calculation
uniform float terrain_height = 20.0;
uniform float noise_frequency = 0.02;

// Surface cliff rock threshold - only apply rocky texture above this Y level
// Below this height, show actual materials for underground mining clarity
uniform float surface_cliff_threshold = 10.0;

// Per-chunk material system (world-space sampling)
uniform sampler3D material_map : filter_nearest;  // 3D texture with material IDs
uniform vec3 chunk_origin = vec3(0.0);  // Chunk world position for UV calculation
uniform bool has_material_map = false;  // Whether this chunk has player-placed materials

// Debug visualization
uniform bool debug_show_chunk_bounds = false;  // Toggle to show chunk boundary lines
uniform bool debug_show_road_zones = false;   // Toggle to show road zone detection

varying vec3 world_pos;
varying vec3 world_normal;
varying vec3 vertex_color;  // Material color from GPU (legacy, kept for compatibility)

// Simple 2D hash/noise for biomes
vec2 hash(vec2 p) {
	p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
	return -1.0 + 2.0 * fract(sin(p) * 43758.5453123);
}

float noise(vec2 p) {
	const float K1 = 0.366025404; // (sqrt(3)-1)/2;
	const float K2 = 0.211324865; // (3-sqrt(3))/6;

	vec2 i = floor(p + (p.x + p.y) * K1);
	vec2 a = p - i + (i.x + i.y) * K2;
	float m = step(a.y, a.x); 
	vec2 o = vec2(m, 1.0 - m);
	vec2 b = a - o + K2;
	vec2 c = a - 1.0 + 2.0 * K2;

	vec3 h = max(0.5 - vec3(dot(a, a), dot(b, b), dot(c, c)), 0.0);
	vec3 n = h * h * h * h * vec3(dot(a, hash(i + 0.0)), dot(b, hash(i + o)), dot(c, hash(i + 1.0)));

	return dot(n, vec3(70.0));
}

// Fractal Brownian Motion for more natural biome shapes
float fbm(vec2 p) {
	float f = 0.0;
	float w = 0.5;
	for (int i = 0; i < 3; i++) {
		f += w * noise(p);
		p *= 2.0;
		w *= 0.5;
	}
	return f;
}

// Procedural road distance (same math as gen_density.glsl)
float get_procedural_road_dist(vec2 pos) {
	if (!procedural_road_enabled || procedural_road_spacing <= 0.0) {
		return 1000.0;
	}
	float local_x = mod(pos.x, procedural_road_spacing);
	float local_z = mod(pos.y, procedural_road_spacing);
	float dist_to_x_road = min(local_x, procedural_road_spacing - local_x);
	float dist_to_z_road = min(local_z, procedural_road_spacing - local_z);
	return min(dist_to_x_road, dist_to_z_road);
}

varying vec3 local_vertex;  // Mesh vertex in local chunk space (0-32)

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = (MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz;
	vertex_color = COLOR.rgb;  // Pass material color to fragment
	local_vertex = VERTEX;  // Pass local position for 3D texture sampling
}

vec4 triplanar_texture(sampler2D p_sampler, vec3 p_weights, vec3 p_triplanar_pos) {
	vec4 samp = vec4(0.0);
	samp += texture(p_sampler, p_triplanar_pos.xy) * p_weights.z;
	samp += texture(p_sampler, p_triplanar_pos.xz) * p_weights.y;
	samp += texture(p_sampler, p_triplanar_pos.zy * vec2(-1.0, 1.0)) * p_weights.x;
	return samp;
}

void fragment() {
	vec3 normal = normalize(world_normal);
	vec3 weights = abs(normal);
	weights = max(weights - 0.2, 0.0);
	weights /= dot(weights, vec3(1.0));
	
	vec3 uv_pos = world_pos * uv_scale;
	
	// Sample all textures (triplanar)
	vec3 col_grass = triplanar_texture(texture_grass, weights, uv_pos).rgb;
	vec3 col_rock = triplanar_texture(texture_rock, weights, uv_pos).rgb;    // Cliff faces
	vec3 col_stone = triplanar_texture(texture_stone, weights, uv_pos).rgb;  // Underground/gravel
	vec3 col_sand = triplanar_texture(texture_sand, weights, uv_pos).rgb;
	vec3 col_snow = triplanar_texture(texture_snow, weights, uv_pos).rgb;
	vec3 col_road = triplanar_texture(texture_road, weights, uv_pos).rgb;
	
	// === NEW: Material from Vertex Color (set by marching_cubes.glsl) ===
	// Material ID is encoded in vertex_color.r channel
	// IDs: 0=Grass, 1=Stone, 2=Ore, 3=Sand, 4=Gravel, 5=Snow, 6=Road, 100+=Player
	int mat_id = int(round(vertex_color.r * 255.0));
	
	// Check for player-placed material override from 3D texture
	// Player materials (100+) are written to material_map when player places blocks
	bool is_player_placed = false;
	if (has_material_map) {
		// Sample material map at vertex position (biased toward solid)
		vec3 biased_pos = local_vertex - normal * 0.8;
		vec3 voxel_pos = floor(biased_pos + vec3(0.5));
		vec3 local_pos = clamp(voxel_pos / 32.0, vec3(0.0), vec3(1.0));
		float mat_raw = texture(material_map, local_pos).r;
		int sampled_id = int(round(mat_raw * 255.0));
		
		// Player-placed materials (100+) override procedural
		if (sampled_id >= 100) {
			mat_id = sampled_id;
			is_player_placed = true;
		}
	}
	
	// === Material Lookup with Smooth Biome Blending ===
	// Use vertex color material as base, but smooth biome transitions for surface materials
	vec3 base_color;
	
	// For surface biome materials (0,3,4,5), apply smooth blending based on fbm
	bool is_surface_biome = (mat_id == 0 || mat_id == 3 || mat_id == 4 || mat_id == 5);
	
	if (is_surface_biome && !is_player_placed) {
		// Smooth biome calculation (same as original shader)
		float biome_val = fbm(world_pos.xz * biome_scale);
		
		// Start with grass as base
		base_color = col_grass;
		
		// Smooth blend to sand
		float sand_mix = smoothstep(-0.2, -0.4, biome_val);
		base_color = mix(base_color, col_sand, sand_mix);
		
		// Smooth blend to gravel (uses stone texture, not rock)
		float gravel_mix = smoothstep(0.2, 0.4, biome_val);
		base_color = mix(base_color, col_stone, gravel_mix);
		
		// Smooth blend to snow
		float snow_mix = smoothstep(0.6, 0.8, biome_val);
		base_color = mix(base_color, col_snow, snow_mix);
	}
	else if (mat_id == 1) {
		base_color = col_stone;  // Underground stone
	} else if (mat_id == 2) {
		base_color = col_stone * vec3(1.2, 1.0, 0.5);  // Ore: golden stone tint
	} else if (mat_id == 6) {
		base_color = col_road;
	} else if (mat_id >= 100) {
		// Player-placed materials
		if (mat_id == 100) base_color = col_grass;
		else if (mat_id == 102) base_color = col_sand;
		else if (mat_id == 103) base_color = col_snow;
		else base_color = col_stone;  // 101 = Stone
	} else {
		base_color = col_grass;  // Fallback
	}
	
	// === Slope-based Cliff Rock (visual enhancement, not material change) ===
	// Only apply to SURFACE cliffs (above threshold). Underground shows raw materials.
	// This ensures players can see stone, ore, etc. when mining underground.
	float slope = normal.y;
	if (!is_player_placed && mat_id != 6) {
		// Height-based surface check with smooth transition
		float surface_blend = smoothstep(surface_cliff_threshold - 2.0, surface_cliff_threshold + 2.0, world_pos.y);
		float cliff_mix = (1.0 - smoothstep(0.5, 0.7, slope)) * surface_blend;
		base_color = mix(base_color, col_rock, cliff_mix);
	}
	
	// === Player Road Overlay (from road_mask texture) ===
	// This allows player-painted roads to overlay procedural materials
	vec2 road_uv = (world_pos.xz + road_mask_offset) * road_mask_scale + 0.5;
	float road_raw = texture(road_mask, road_uv).r;
	float road_slope_mask = smoothstep(0.7, 0.85, slope);
	float road_intensity = is_player_placed ? 0.0 : road_raw * road_slope_mask;
	base_color = mix(base_color, col_road, road_intensity);
	
	// === Procedural Road Edge Blending (toggleable) ===
	// Creates soft gradient at road edges instead of hard material boundary
	if (road_edge_blend_enabled && !is_player_placed && mat_id != 6) {
		float road_dist = get_procedural_road_dist(world_pos.xz);
		// Actual voxel road is at road_width * 0.5 (4.0 for 8.0 width)
		float actual_road_edge = procedural_road_width * 0.43;
		float inner_edge = actual_road_edge - road_edge_blend_width;
		if (road_dist >= inner_edge && road_dist <= actual_road_edge) {
			float edge_blend = 1.0 - smoothstep(inner_edge, actual_road_edge, road_dist);
			edge_blend *= road_slope_mask;
			base_color = mix(base_color, col_road, edge_blend);
		}
	}
	
	// === Dynamic Weather Snow ===
	// Applies based on global_snow_amount, sticks to flat surfaces
	if (!is_player_placed) {
		float weather_snow = global_snow_amount * smoothstep(0.3, 0.6, slope);
		weather_snow *= smoothstep(0.0, 1.0, noise(world_pos.xz * 0.5) + 0.5);
		ALBEDO = mix(base_color, col_snow, clamp(weather_snow, 0.0, 1.0));
	} else {
		ALBEDO = base_color;
	}
	
	// --- Debug: Road Zone Visualization ---
	// Red = voxel says road, Green = procedural says road, Yellow = both agree
	if (debug_show_road_zones) {
		float road_dist_debug = get_procedural_road_dist(world_pos.xz);
		bool in_procedural_road = (road_dist_debug < procedural_road_width);
		bool voxel_is_road = (mat_id == 6);
		
		if (voxel_is_road && in_procedural_road) {
			ALBEDO = mix(ALBEDO, vec3(1.0, 1.0, 0.0), 0.6);  // Yellow = both agree
		} else if (voxel_is_road) {
			ALBEDO = mix(ALBEDO, vec3(1.0, 0.0, 0.0), 0.6);  // Red = voxel only (spillover)
		} else if (in_procedural_road) {
			ALBEDO = mix(ALBEDO, vec3(0.0, 1.0, 0.0), 0.6);  // Green = procedural only (crack)
		}
	}
	
	// --- Debug: Chunk Boundary Visualization ---
	if (debug_show_chunk_bounds) {
		float chunk_size = 32.0;
		// Distance to nearest chunk boundary in X and Z
		float dist_x = min(mod(world_pos.x, chunk_size), chunk_size - mod(world_pos.x, chunk_size));
		float dist_z = min(mod(world_pos.z, chunk_size), chunk_size - mod(world_pos.z, chunk_size));
		float dist_y = min(mod(world_pos.y, chunk_size), chunk_size - mod(world_pos.y, chunk_size));
		
		// Draw red lines at X/Z boundaries, blue at Y
		float line_width = 0.3;
		if (dist_x < line_width || dist_z < line_width) {
			ALBEDO = mix(ALBEDO, vec3(1.0, 0.0, 0.0), 0.8);  // Red for X/Z bounds
		}
		if (dist_y < line_width) {
			ALBEDO = mix(ALBEDO, vec3(0.0, 0.0, 1.0), 0.8);  // Blue for Y bounds
		}
	}
}