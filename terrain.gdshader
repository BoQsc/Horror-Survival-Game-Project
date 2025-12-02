shader_type spatial;

uniform sampler2D texture_grass : source_color, filter_linear_mipmap;
uniform sampler2D texture_rock : source_color, filter_linear_mipmap;
uniform sampler2D texture_sand : source_color, filter_linear_mipmap;
uniform sampler2D texture_snow : source_color, filter_linear_mipmap;

uniform float uv_scale = 0.1;

varying vec3 world_pos;
varying vec3 world_normal;

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
	weights = max(weights - 0.2, 0.0); // Sharpen
	weights /= dot(weights, vec3(1.0));
	
	vec3 uv_pos = world_pos * uv_scale;
	
	// Sample textures
	vec3 col_grass = triplanar_texture(texture_grass, weights, uv_pos).rgb;
	vec3 col_rock = triplanar_texture(texture_rock, weights, uv_pos).rgb;
	vec3 col_sand = triplanar_texture(texture_sand, weights, uv_pos).rgb;
	vec3 col_snow = triplanar_texture(texture_snow, weights, uv_pos).rgb;
	
	float height = world_pos.y;
	float slope = normal.y; // 1.0 is up, 0.0 is side
	
	// 1. Height Mixing (Sand -> Grass -> Snow)
	// Base is sand
	vec3 albedo_height = col_sand;
	
	// Grass transition
	float grass_mix = smoothstep(11.0, 13.0, height);
	albedo_height = mix(albedo_height, col_grass, grass_mix);
	
	// Snow transition
	float snow_mix = smoothstep(17.0, 19.0, height);
	albedo_height = mix(albedo_height, col_snow, snow_mix);
	
	// 2. Slope Mixing (Rock on steep slopes)
	// If slope is < 0.7 (approx 45 degrees), blend in rock
	// But snow often sticks to rocks too, so maybe rock is under snow?
	// Let's say rock overrides grass/sand but maybe not snow at high peaks?
	// For now, rock overrides all for simplicity on steep cliffs.
	
	float rock_mix = 1.0 - smoothstep(0.5, 0.8, slope);
	
	// Don't put rock on snow peaks if it's flat? 
	// Actually steep snow mountains have rock faces. 
	// Let's mix rock based on slope strictly.
	
	ALBEDO = mix(albedo_height, col_rock, rock_mix);
}
