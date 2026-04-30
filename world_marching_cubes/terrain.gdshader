shader_type spatial;

uniform sampler2D texture_grass : source_color, filter_linear_mipmap;
uniform sampler2D texture_rock : source_color, filter_linear_mipmap;   // For cliff faces only
uniform sampler2D texture_stone : source_color, filter_linear_mipmap;  // For underground/gravel/ore
uniform sampler2D texture_sand : source_color, filter_linear_mipmap;
uniform sampler2D texture_snow : source_color, filter_linear_mipmap;
uniform sampler2D texture_road : source_color, filter_linear_mipmap;  // Asphalt texture

uniform float uv_scale = 0.5;
uniform float biome_scale = 0.002; // Match gen_density.glsl for aligned blending
uniform float global_snow_amount : hint_range(0.0, 1.0) = 0.0;
uniform bool biome_blending_enabled = true;  // Toggle: false = exact mat_id, true = smooth per-pixel blending
uniform bool cliff_rock_enabled = true;  // Toggle: true = rocky texture on steep slopes

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
uniform float road_edge_blend_width = 3.0;  // Width of the blend zone in world units

// Terrain parameters for per-pixel material calculation
uniform float terrain_height = 20.0;
uniform float noise_frequency = 0.02;

// Surface cliff rock threshold - only apply rocky texture above this Y level
// Below this height, show actual materials for underground mining clarity
uniform float surface_cliff_threshold = 10.0;

// Per-chunk material system (world-space sampling)
uniform sampler3D material_map : filter_nearest;  // 3D texture with material IDs
uniform bool has_material_map = false;  // Whether this chunk has player-placed materials

// Debug visualization
uniform bool debug_show_chunk_bounds = false;  // Toggle to show chunk boundary lines
uniform bool debug_show_road_zones = false;   // Toggle to show road zone detection
uniform bool use_world_map = false;           // Use exact material IDs instead of procedural noise
uniform bool world_map_fragment_lookup_enabled = false; // Heightfield LOD samples baked map textures directly
uniform sampler2D world_map_biome_map : hint_default_black, filter_nearest, repeat_disable;
uniform sampler2D world_map_road_map : hint_default_black, filter_nearest, repeat_disable;
uniform float world_map_texture_scale = 0.0005;


varying vec3 world_pos;
varying vec3 world_normal;
// Dual-material system: flat = no GPU interpolation, smooth = interpolated
varying flat vec2 material_ids;   // R=mat_A/255, G=mat_B/255 (NOT interpolated)
varying float blend_factor;       // 0.0=100% mat_A, 1.0=100% mat_B (smoothly interpolated)

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

// 3D hash for road height calculation
float hash3d(vec3 p) {
	p = fract(p * 0.3183099 + 0.1);
	p *= 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

// 3D noise for road height
float noise3d(vec3 x) {
	vec3 i = floor(x);
	vec3 f = fract(x);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(hash3d(i + vec3(0,0,0)), hash3d(i + vec3(1,0,0)), f.x),
	               mix(hash3d(i + vec3(0,1,0)), hash3d(i + vec3(1,1,0)), f.x), f.y),
	           mix(mix(hash3d(i + vec3(0,0,1)), hash3d(i + vec3(1,0,1)), f.x),
	               mix(hash3d(i + vec3(0,1,1)), hash3d(i + vec3(1,1,1)), f.x), f.y), f.z);
}

// 3D Fractal Brownian Motion for seamless underground variation
float fbm3d(vec3 p) {
	float f = 0.0;
	float w = 0.5;
	for (int i = 0; i < 3; i++) {
		f += w * noise3d(p);
		p *= 2.0;
		w *= 0.5;
	}
	return f;
}

float get_road_info(vec2 pos, float spacing, out float road_height) {
	if (spacing <= 0.0) {
		road_height = 0.0;
		return 1000.0;
	}

	float cell_x = floor(pos.x / spacing);
	float cell_z = floor(pos.y / spacing);

	float local_x = mod(pos.x, spacing);
	float local_z = mod(pos.y, spacing);

	float dist_to_x_road = min(local_x, spacing - local_x);
	float dist_to_z_road = min(local_z, spacing - local_z);

	float h1 = noise3d(vec3(cell_x * spacing, 0.0, cell_z * spacing) * 0.008) * 3.0 + 12.0;
	float h2 = noise3d(vec3((cell_x + 1.0) * spacing, 0.0, cell_z * spacing) * 0.008) * 3.0 + 12.0;
	float h3 = noise3d(vec3(cell_x * spacing, 0.0, (cell_z + 1.0) * spacing) * 0.008) * 3.0 + 12.0;
	float h4 = noise3d(vec3((cell_x + 1.0) * spacing, 0.0, (cell_z + 1.0) * spacing) * 0.008) * 3.0 + 12.0;

	float tx = local_x / spacing;
	float tz = local_z / spacing;
	float interpolated_height = mix(mix(h1, h2, tx), mix(h3, h4, tx), tz);

	float base_level = floor(interpolated_height);
	float frac = interpolated_height - base_level;
	float flat_size = 0.45;

	if (frac < flat_size) {
		road_height = base_level;
	} else if (frac > 1.0 - flat_size) {
		road_height = base_level + 1.0;
	} else {
		float ramp_t = (frac - flat_size) / (1.0 - 2.0 * flat_size);
		road_height = base_level + smoothstep(0.0, 1.0, ramp_t);
	}

	return min(dist_to_x_road, dist_to_z_road);
}

varying vec3 local_vertex;  // Mesh vertex in local chunk space (0-32)

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = (MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz;
	// Dual-material: R=mat_A, G=mat_B, B=blend
	material_ids = COLOR.rg;    // flat — provoking vertex, no interpolation
	blend_factor = COLOR.b;     // smooth — GPU interpolates across triangle
	local_vertex = VERTEX;
}

vec4 triplanar_texture(sampler2D p_sampler, vec3 p_weights, vec3 p_triplanar_pos) {
	vec4 samp = vec4(0.0);
	samp += texture(p_sampler, p_triplanar_pos.xy) * p_weights.z;
	samp += texture(p_sampler, p_triplanar_pos.xz) * p_weights.y;
	samp += texture(p_sampler, p_triplanar_pos.zy * vec2(-1.0, 1.0)) * p_weights.x;
	return samp;
}

// Procedural Fragment Material - Completely bypasses vertex color jagged edges
// Calculates natural terrain texture dynamically per-pixel
vec3 get_procedural_color(vec3 w_pos, vec3 col_grass, vec3 col_stone, vec3 col_sand, vec3 col_snow, vec3 col_road) {
	float t_height = terrain_height + noise3d(vec3(w_pos.x, 0.0, w_pos.z) * noise_frequency) * terrain_height;
	float depth = t_height - w_pos.y;
	
	// 1. Base Biome (Surface)
	float biome_val = fbm(w_pos.xz * biome_scale);
	float blend_w = 0.002; // Tighter blend to match voxel material data exactly
	float w_sand = 1.0 - smoothstep(-0.2 - blend_w, -0.2 + blend_w, biome_val);
	float w_snow = smoothstep(0.6 - blend_w, 0.6 + blend_w, biome_val);
	float w_gravel = smoothstep(0.2 - blend_w, 0.2 + blend_w, biome_val) * (1.0 - w_snow);
	float w_grass = max(0.0, 1.0 - w_sand - w_snow - w_gravel);
	vec3 final_col = col_grass * w_grass + col_sand * w_sand + col_stone * w_gravel + col_snow * w_snow;
	
	// 2. Underground Blending
	// Base the stone transition purely on depth from the natural terrain surface
	float underground_mix = smoothstep(8.0, 12.0, depth);
	
	if (underground_mix > 0.0) {
		vec3 under_col = col_stone;
		float ore_noise = noise3d(w_pos * 0.15);
		if (ore_noise > 0.75 && depth > 8.0) {
			under_col = col_stone * vec3(1.2, 1.0, 0.5); // Ore
		} else {
			float stone_var = fbm3d(w_pos * 0.02);
			if (stone_var > 0.25) under_col = col_stone * vec3(0.7, 0.65, 0.6); // Granite
		}
		final_col = mix(final_col, under_col, underground_mix);
	}
	
	// 3. Procedural Road Overlay
	// Apply AFTER underground blending! If a road cuts deep into a hill,
	// the ground is stone, but the road overlays asphalt on top of the stone.
	// This naturally fixes the problem without infinite cylinder mask hacks.
	if (procedural_road_enabled) {
		float r_height = 0.0;
		float r_dist = get_road_info(w_pos.xz, procedural_road_spacing, r_height);
		float r_height_diff = abs(w_pos.y - r_height);
		
		// Smoothstep edges of the road
		float edge_width = road_edge_blend_enabled ? road_edge_blend_width : 0.0;
		float r_mix = 1.0 - smoothstep(max(0.0, procedural_road_width * 0.5 - 1.0), procedural_road_width * 0.5 + edge_width, r_dist);
		float r_h_mix = 1.0 - smoothstep(1.5, 3.0, r_height_diff);
		float is_road = r_mix * r_h_mix;
		final_col = mix(final_col, col_road, is_road);
	}
	
	return final_col;
}

// World-map road blending: samples road_mask per-pixel for smooth edges
// Called from fragment() to overlay road on procedural color in world map mode
vec3 apply_world_map_road(vec3 color, vec3 col_road, vec3 w_pos) {
	vec2 road_uv = (w_pos.xz + road_mask_offset) * road_mask_scale + 0.5;
	float road_raw = texture(road_mask, road_uv).r;
	// Smooth the binary road mask edges for a gradient transition
	float road_blend = smoothstep(0.1, 0.9, road_raw);
	return mix(color, col_road, road_blend);
}

vec3 sample_exact_material_color(int mat_id, vec3 weights, vec3 uv_pos) {
	bool is_placed = (mat_id >= 100);
	int id = is_placed ? (mat_id - 100) : mat_id;

	if (id == 0) return triplanar_texture(texture_grass, weights, uv_pos).rgb;
	else if (id == 1) return triplanar_texture(texture_stone, weights, uv_pos).rgb;
	else if (id == 2) return triplanar_texture(texture_stone, weights, uv_pos).rgb * vec3(1.2, 1.0, 0.5);  // Ore
	else if (id == 3) return triplanar_texture(texture_sand, weights, uv_pos).rgb;
	else if (id == 4) return triplanar_texture(texture_stone, weights, uv_pos).rgb;  // Gravel
	else if (id == 5) return triplanar_texture(texture_snow, weights, uv_pos).rgb;
	else if (id == 6) return triplanar_texture(texture_road, weights, uv_pos).rgb;
	else if (id == 9) return triplanar_texture(texture_stone, weights, uv_pos).rgb * vec3(0.7, 0.65, 0.6);  // Granite
	else return triplanar_texture(texture_grass, weights, uv_pos).rgb;
}

int normalize_world_map_biome_id(int biome_id) {
	if (biome_id == 0 || biome_id == 3 || biome_id == 4 || biome_id == 5) {
		return biome_id;
	}
	return 0;
}

int sample_world_map_fragment_material(vec3 w_pos) {
	ivec2 biome_size = textureSize(world_map_biome_map, 0);
	if (biome_size.x <= 0 || biome_size.y <= 0) {
		return 0;
	}

	vec2 uv = clamp(w_pos.xz * world_map_texture_scale + vec2(0.5), vec2(0.0), vec2(0.999999));
	ivec2 biome_px = clamp(ivec2(floor(uv * vec2(biome_size))), ivec2(0), biome_size - ivec2(1));
	int biome_id = int(round(texelFetch(world_map_biome_map, biome_px, 0).r * 255.0));

	ivec2 road_size = textureSize(world_map_road_map, 0);
	if (road_size.x > 0 && road_size.y > 0) {
		ivec2 road_px = clamp(ivec2(floor(uv * vec2(road_size))), ivec2(0), road_size - ivec2(1));
		int road_id = int(round(texelFetch(world_map_road_map, road_px, 0).r * 255.0));
		if (road_id > 128 || biome_id == 6) {
			return 6;
		}
	}

	return normalize_world_map_biome_id(biome_id);
}

// Resolve a material ID to its texture color
vec3 resolve_material_color(int mat_id, vec3 col_grass, vec3 col_stone, vec3 col_sand, vec3 col_snow, vec3 col_road, vec3 procedural_col) {
	bool is_placed = (mat_id >= 100);
	int id = is_placed ? (mat_id - 100) : mat_id;
	
	if (is_placed) {
		// Player-placed materials (100+): Use absolute texture
		if (id == 0) return col_grass;
		else if (id == 1) return col_stone;
		else if (id == 2) return col_stone * vec3(1.2, 1.0, 0.5);  // Ore
		else if (id == 3) return col_sand;
		else if (id == 4) return col_stone;  // Gravel
		else if (id == 5) return col_snow;
		else if (id == 6) return col_road;
		else if (id == 9) return col_stone * vec3(0.7, 0.65, 0.6);  // Granite
		else return col_grass;
	} else if (use_world_map) {
		if (id == 0) return col_grass;
		else if (id == 1) return col_stone;
		else if (id == 2) return col_stone * vec3(1.2, 1.0, 0.5);  // Ore
		else if (id == 3) return col_sand;
		else if (id == 4) return col_stone;  // Gravel
		else if (id == 5) return col_snow;
		else if (id == 6) return col_road;
		else if (id == 9) return col_stone * vec3(0.7, 0.65, 0.6);  // Granite
		else return col_grass;
	} else {
		// Natural voxel: honor road material in procedural mode, otherwise use the
		// exact world-map material color path above.
		if (id == 6 && !use_world_map) return col_road;
		return procedural_col;
	}
}

void fragment() {
	vec3 normal = normalize(world_normal);
	vec3 weights = abs(normal);
	weights = max(weights - 0.2, 0.0);
	weights /= dot(weights, vec3(1.0));
	
	vec3 uv_pos = world_pos * uv_scale;
	
	// === DUAL-MATERIAL DECODING ===
	// material_ids is flat (from provoking vertex, NOT interpolated)
	// blend_factor is smooth (GPU interpolated across triangle)
	int mat_id_A = int(round(material_ids.x * 255.0));
	int mat_id_B = int(round(material_ids.y * 255.0));
	float blend = clamp(blend_factor, 0.0, 1.0);
	
	// Check for player-placed material override from 3D texture
	bool is_player_placed = false;
	if (has_material_map) {
		vec3 biased_pos = local_vertex - normal * 0.8;
		vec3 voxel_pos = floor(biased_pos + vec3(0.5));
		vec3 local_pos = clamp(voxel_pos / 32.0, vec3(0.0), vec3(1.0));
		float mat_raw = texture(material_map, local_pos).r;
		int sampled_id = int(round(mat_raw * 255.0));
		if (sampled_id >= 100) {
			is_player_placed = true;
		}
	}
	// Also flag if vertex data indicates player material
	if (mat_id_A >= 100 || mat_id_B >= 100) {
		is_player_placed = true;
	}
	
	// === Material Color Resolution ===
	vec3 base_color;
	
	// Only pay for the procedural biome/road layer when it is actually needed.
	vec3 procedural_perfect_color = vec3(0.0);
	vec3 col_grass = vec3(0.0);
	vec3 col_rock = vec3(0.0);
	vec3 col_stone = vec3(0.0);
	vec3 col_sand = vec3(0.0);
	vec3 col_snow = vec3(0.0);
	vec3 col_road = vec3(0.0);

	if (!use_world_map) {
		col_grass = triplanar_texture(texture_grass, weights, uv_pos).rgb;
		col_rock = triplanar_texture(texture_rock, weights, uv_pos).rgb;    // Cliff faces
		col_stone = triplanar_texture(texture_stone, weights, uv_pos).rgb;  // Underground/gravel
		col_sand = triplanar_texture(texture_sand, weights, uv_pos).rgb;
		col_snow = triplanar_texture(texture_snow, weights, uv_pos).rgb;
		col_road = triplanar_texture(texture_road, weights, uv_pos).rgb;

		procedural_perfect_color = get_procedural_color(world_pos, col_grass, col_stone, col_sand, col_snow, col_road);
		if (mat_id_A == mat_id_B || abs(blend) < 0.001) {
			// Single material lookup
			int mat_id = (abs(blend) < 0.001) ? mat_id_A : ((blend > 0.999) ? mat_id_B : mat_id_A);
			base_color = resolve_material_color(mat_id, col_grass, col_stone, col_sand, col_snow, col_road, procedural_perfect_color);
		} else {
			// Dual material transition (Smoothly blends natural terrain with player-placed blocks)
			vec3 color_A = resolve_material_color(mat_id_A, col_grass, col_stone, col_sand, col_snow, col_road, procedural_perfect_color);
			vec3 color_B = resolve_material_color(mat_id_B, col_grass, col_stone, col_sand, col_snow, col_road, procedural_perfect_color);
			base_color = mix(color_A, color_B, blend);
		}
	} else {
		if (world_map_fragment_lookup_enabled && !is_player_placed) {
			base_color = sample_exact_material_color(sample_world_map_fragment_material(world_pos), weights, uv_pos);
		} else if (mat_id_A == mat_id_B || abs(blend) < 0.001 || blend > 0.999) {
			// Single material lookup
			int mat_id = (blend > 0.999) ? mat_id_B : mat_id_A;
			base_color = sample_exact_material_color(mat_id, weights, uv_pos);
		} else {
			// Dual material transition (Smoothly blends natural terrain with player-placed blocks)
			vec3 color_A = sample_exact_material_color(mat_id_A, weights, uv_pos);
			vec3 color_B = sample_exact_material_color(mat_id_B, weights, uv_pos);
			base_color = mix(color_A, color_B, blend);
		}
	}

	// Slope needed for road and weather effects
	float slope = normal.y;
	
	// === Slope-based Cliff Rock (visual enhancement, not material change) ===
	// Only apply to SURFACE cliffs (above threshold). Underground shows raw materials.
	// This ensures players can see stone, ore, etc. when mining underground.
	if (cliff_rock_enabled && !use_world_map && !is_player_placed && mat_id_A != 6 && mat_id_B != 6) {
		// Height-based surface check with smooth transition
		float surface_blend = smoothstep(surface_cliff_threshold - 2.0, surface_cliff_threshold + 2.0, world_pos.y);
		float cliff_mix = (1.0 - smoothstep(0.5, 0.7, slope)) * surface_blend;
		vec3 col_rock = triplanar_texture(texture_rock, weights, uv_pos).rgb;
		// Apply partial transparency to the rock texture so the underlying material remains slightly visible (e.g. 80% max opacity)
		base_color = mix(base_color, col_rock, cliff_mix * 0.8);
	}
	
	// === Player Road Overlay (from road_mask texture) ===
	// This allows player-painted roads to overlay procedural materials
	if (!use_world_map) {
		vec2 road_uv = (world_pos.xz + road_mask_offset) * road_mask_scale + 0.5;
		float road_raw = texture(road_mask, road_uv).r;
		float road_slope_mask = smoothstep(0.7, 0.85, slope);
		float road_intensity = is_player_placed ? 0.0 : road_raw * road_slope_mask;
		vec3 col_road = triplanar_texture(texture_road, weights, uv_pos).rgb;
		base_color = mix(base_color, col_road, road_intensity);
	}
	
	
	// === Dynamic Weather Snow ===
	// Applies based on global_snow_amount, sticks to flat surfaces
	if (!is_player_placed) {
		if (use_world_map && global_snow_amount > 0.0) {
			col_snow = triplanar_texture(texture_snow, weights, uv_pos).rgb;
		}
		float weather_snow = global_snow_amount * smoothstep(0.3, 0.6, slope);
		weather_snow *= smoothstep(0.0, 1.0, noise(world_pos.xz * 0.5) + 0.5);
		ALBEDO = mix(base_color, col_snow, clamp(weather_snow, 0.0, 1.0));
	} else {
		ALBEDO = base_color;
	}
	
	// --- Debug: Road Zone Visualization ---
	// Red = voxel says road, Green = procedural says road, Yellow = both agree
	if (debug_show_road_zones) {
		float road_dist_debug = 1000.0;
		if (procedural_road_enabled) {
			float road_height_debug = 0.0;
			road_dist_debug = get_road_info(world_pos.xz, procedural_road_spacing, road_height_debug);
		}
		bool in_procedural_road = (road_dist_debug < procedural_road_width);
		bool voxel_is_road = (mat_id_A == 6 || mat_id_B == 6);
		
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
