shader_type spatial;
render_mode blend_mix, cull_back, depth_draw_always;

uniform vec3 albedo : source_color = vec3(0.0, 0.32, 0.43);
uniform vec3 albedo_deep : source_color = vec3(0.0, 0.1, 0.3);
uniform float metallic : hint_range(0.0, 1.0) = 0.5;
uniform float roughness : hint_range(0.0, 1.0) = 0.1;
uniform float beer_factor = 0.2;
uniform float foam_level = 0.5;

uniform sampler2D depth_texture : hint_depth_texture, filter_linear_mipmap;

float fresnel(float amount, vec3 normal, vec3 view) {
	return pow((1.0 - clamp(dot(normalize(normal), normalize(view)), 0.0, 1.0)), amount);
}

void fragment() {
	// Depth Magic
	float depth = texture(depth_texture, SCREEN_UV).x;
	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, depth);
	vec4 view = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	view.xyz /= view.w;
	float linear_depth = -view.z;
	float linear_surface_depth = -VERTEX.z;
	float depth_diff = linear_depth - linear_surface_depth;
	
	// Beer's Law (Absorb light based on depth)
	// depth_diff is the distance from water surface to the terrain behind it.
	// If depth_diff is large, we want more of albedo_deep and higher alpha.
	float depth_alpha = clamp(1.0 - exp(-depth_diff * beer_factor), 0.0, 1.0);
	
	vec3 final_albedo = mix(albedo, albedo_deep, depth_alpha);
	
	// Foam Logic (Edges)
	// If depth_diff is very small (near 0), we are at the shoreline.
	float foam = clamp(1.0 - (depth_diff / foam_level), 0.0, 1.0);
	
	// Apply Foam
	final_albedo = mix(final_albedo, vec3(1.0, 1.0, 1.0), foam);
	
	// Fresnel (Reflection at glancing angles)
	float f = fresnel(4.0, NORMAL, VIEW);
	
	ALBEDO = final_albedo + (vec3(1.0) * f * 0.5);
	METALLIC = metallic;
	ROUGHNESS = roughness;
	
	// Base alpha + depth absorption + foam
	// We want water to be at least somewhat visible (0.4) but get more opaque with depth
	ALPHA = clamp(0.4 + depth_alpha * 0.6 + foam, 0.0, 1.0);
}
