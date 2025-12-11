shader_type spatial;

uniform sampler2D texture_grass : source_color, filter_linear_mipmap;
uniform sampler2D texture_rock : source_color, filter_linear_mipmap;
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

// Terrain parameters for per-pixel material calculation
uniform float terrain_height = 20.0;
uniform float noise_frequency = 0.02;

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

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = (MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz;
	vertex_color = COLOR.rgb;  // Pass material color to fragment
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
	
	// Sample all textures
	vec3 col_grass = triplanar_texture(texture_grass, weights, uv_pos).rgb;
	vec3 col_rock = triplanar_texture(texture_rock, weights, uv_pos).rgb;
	vec3 col_sand = triplanar_texture(texture_sand, weights, uv_pos).rgb;
	vec3 col_snow = triplanar_texture(texture_snow, weights, uv_pos).rgb;
	vec3 col_road = triplanar_texture(texture_road, weights, uv_pos).rgb;
	
	// --- Per-Pixel Material Detection (using world position, not vertex color) ---
	// This eliminates rectangular boundaries from voxel grid sampling
	
	// Calculate terrain height at this pixel using same noise as gen_density.glsl
	float base_height = terrain_height;
	float hill_height = noise(world_pos.xz * noise_frequency) * terrain_height;
	float terrain_surface = base_height + hill_height;
	
	// Account for roads in material calculation
	float road_dist = get_procedural_road_dist(world_pos.xz);
	float effective_surface = terrain_surface;
	if (road_dist < procedural_road_width * 2.0) {
		// Near road - use lower effective surface
		float road_blend = smoothstep(procedural_road_width * 2.0, procedural_road_width * 0.5, road_dist);
		effective_surface = mix(terrain_surface, terrain_surface - 5.0, road_blend);
	}
	
	// Calculate depth below surface
	float depth = effective_surface - world_pos.y;
	
	// Smooth material blending based on depth (no hard edges)
	float is_grass = 1.0 - smoothstep(10.0, 15.0, depth);  // Grass fades to stone at depth 10-15
	float is_ore = 0.0;  // Ore could be noise-based if needed
	float is_stone = 1.0 - is_grass;
	
	// Mix textures based on material
	vec3 material_color = col_grass * is_grass + col_rock * is_stone;
	
	// --- Biome Logic (applied on top of material) ---
	// Use world X/Z to add biome variation
	float biome_val = fbm(world_pos.xz * biome_scale);
	
	// Only apply biome blending on grass material (surface)
	vec3 biome_color = material_color;
	if (is_grass > 0.5) {
		// Mix Sand -> Grass
		float sand_mix = smoothstep(-0.2, -0.4, biome_val);
		biome_color = mix(biome_color, col_sand, sand_mix);
		
		// Mix Grass -> Gravel (Rock)
		float gravel_mix = smoothstep(0.2, 0.4, biome_val);
		biome_color = mix(biome_color, col_rock, gravel_mix);
		
		// Mix Gravel -> Snow Biome
		float snow_biome_mix = smoothstep(0.6, 0.8, biome_val);
		biome_color = mix(biome_color, col_snow, snow_biome_mix);
	}
	
	// --- Slope Logic (Steep cliffs are rock) ---
	float slope = normal.y;
	float cliff_mix = 1.0 - smoothstep(0.5, 0.7, slope);
	biome_color = mix(biome_color, col_rock, cliff_mix);
	
	// --- Procedural Road Texture ---
	float proc_road_dist = get_procedural_road_dist(world_pos.xz);
	float proc_road_intensity = 0.0;
	if (proc_road_dist < procedural_road_width) {
		// Only on flat surfaces (slope > 0.85)
		float road_slope_ok = smoothstep(0.8, 0.9, slope);
		proc_road_intensity = smoothstep(procedural_road_width, procedural_road_width * 0.3, proc_road_dist) * road_slope_ok;
	}
	biome_color = mix(biome_color, col_road, proc_road_intensity);
	
	// --- Player Road Overlay (mask-based) ---
	// Sample road mask at world position to get road intensity
	vec2 road_uv = (world_pos.xz + road_mask_offset) * road_mask_scale + 0.5;
	float road_raw = texture(road_mask, road_uv).r;
	
	// Relaxed slope check for Road Type 3 graded surfaces
	float road_slope_mask = smoothstep(0.7, 0.85, slope);
	float road_intensity = road_raw * road_slope_mask;
	
	biome_color = mix(biome_color, col_road, road_intensity);
	
	// --- Dynamic Weather Snow ---
	// Applies everywhere based on global_snow_amount
	// Snow sticks to flat surfaces more (slope > 0.5)
	float weather_snow = global_snow_amount * smoothstep(0.3, 0.6, slope);
	// Also adds some noise to the snow edge
	weather_snow *= smoothstep(0.0, 1.0, noise(world_pos.xz * 0.5) + 0.5); 
	
	ALBEDO = mix(biome_color, col_snow, clamp(weather_snow, 0.0, 1.0));
}