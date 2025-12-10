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

varying vec3 world_pos;
varying vec3 world_normal;

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

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = (MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz;
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
	
	// --- Biome Logic ---
	// Use world X/Z to pick a biome value [-1, 1]
	float biome_val = fbm(world_pos.xz * biome_scale);
	
	// Map biome_val to types:
	// < -0.3  : Desert (Sand)
	// -0.3 to 0.2 : Grass
	// 0.2 to 0.6 : Gravel/Rock (Mountain base?)
	// > 0.6   : Snow Biome (Tundra)
	
	vec3 biome_color = col_grass; // Default
	
	// Mix Sand -> Grass
	float sand_mix = smoothstep(-0.2, -0.4, biome_val); // Fade into sand as value gets lower
	biome_color = mix(biome_color, col_sand, sand_mix);
	
	// Mix Grass -> Gravel (Rock)
	float gravel_mix = smoothstep(0.2, 0.4, biome_val);
	biome_color = mix(biome_color, col_rock, gravel_mix);
	
	// Mix Gravel -> Snow Biome
	float snow_biome_mix = smoothstep(0.6, 0.8, biome_val);
	biome_color = mix(biome_color, col_snow, snow_biome_mix);
	
	// --- Slope Logic (Steep cliffs are rock) ---
	float slope = normal.y;
	float cliff_mix = 1.0 - smoothstep(0.5, 0.7, slope);
	biome_color = mix(biome_color, col_rock, cliff_mix);
	
	// --- Road Overlay ---
	// Sample road mask at world position to get road intensity
	vec2 road_uv = (world_pos.xz + road_mask_offset) * road_mask_scale + 0.5;
	float road_intensity = texture(road_mask, road_uv).r;
	biome_color = mix(biome_color, col_road, road_intensity);
	
	// --- Dynamic Weather Snow ---
	// Applies everywhere based on global_snow_amount
	// Snow sticks to flat surfaces more (slope > 0.5)
	float weather_snow = global_snow_amount * smoothstep(0.3, 0.6, slope);
	// Also adds some noise to the snow edge
	weather_snow *= smoothstep(0.0, 1.0, noise(world_pos.xz * 0.5) + 0.5); 
	
	ALBEDO = mix(biome_color, col_snow, clamp(weather_snow, 0.0, 1.0));
}