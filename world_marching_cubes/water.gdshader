shader_type spatial;
render_mode blend_mix, cull_disabled, depth_draw_always, depth_prepass_alpha;

// Water colors - dark green tones
uniform vec3 albedo : source_color = vec3(0.05, 0.18, 0.12);          // Dark green
uniform vec3 albedo_deep : source_color = vec3(0.01, 0.06, 0.04);     // Very dark green-black
uniform vec3 albedo_shallow : source_color = vec3(0.1, 0.3, 0.2);     // Lighter greenish
uniform float metallic : hint_range(0.0, 1.0) = 0.4;
uniform float roughness : hint_range(0.0, 1.0) = 0.05;
uniform float beer_factor = 0.25;

// Wave animation
uniform float wave_speed = 0.5;
uniform float wave_scale = 0.008;  // Smaller = larger waves

// Edge effects
uniform float foam_intensity = 0.25;
uniform float foam_threshold = 0.5;
uniform vec3 foam_color : source_color = vec3(0.5, 0.7, 0.8);

// Refraction settings
uniform float refraction_strength = 0.008;  // Very subtle distortion

// Normal texture for detailed ripples
uniform sampler2D water_normal_texture : hint_normal, filter_linear_mipmap, repeat_enable;
uniform float normal_texture_scale = 0.05;  // Tiling scale
uniform float normal_texture_strength = 0.4;  // How much texture affects normal

uniform sampler2D depth_texture : hint_depth_texture, filter_linear_mipmap;
uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;

// Pass world position from vertex shader so it's truly world-space
varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	// Lift water slightly to reduce Z-fighting with coplanar terrain
	VERTEX.y += 0.05;
}

// Improved noise - smoother gradient noise (avoids rectangular artifacts)
vec2 hash22(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.xx + p3.yz) * p3.zy);
}

float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	
	// Quintic interpolation for smoother results
	vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	
	// Four corners
	float a = dot(hash22(i) - 0.5, f);
	float b = dot(hash22(i + vec2(1.0, 0.0)) - 0.5, f - vec2(1.0, 0.0));
	float c = dot(hash22(i + vec2(0.0, 1.0)) - 0.5, f - vec2(0.0, 1.0));
	float d = dot(hash22(i + vec2(1.0, 1.0)) - 0.5, f - vec2(1.0, 1.0));
	
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y) + 0.5;
}

// Fractal Brownian Motion for organic waves
float fbm(vec2 p, float time) {
	float f = 0.0;
	float amp = 0.5;
	// Each octave moves in different directions for organic feel
	f += amp * noise(p * 1.0 + vec2(time * 0.4, time * 0.1)); amp *= 0.5;
	f += amp * noise(p * 2.0 - vec2(time * 0.3, -time * 0.2)); amp *= 0.5;
	f += amp * noise(p * 4.0 + vec2(-time * 0.2, time * 0.15)); amp *= 0.5;
	f += amp * noise(p * 8.0 - vec2(time * 0.1, time * 0.25));
	return f;
}

float fresnel(float amount, vec3 normal, vec3 view) {
	return pow((1.0 - clamp(dot(normalize(normal), normalize(view)), 0.0, 1.0)), amount);
}

void fragment() {
	float time = TIME * wave_speed;
	vec2 uv = world_pos.xz * wave_scale;  // World-space UV, won't move with camera
	
	// Generate smooth wave normal from FBM (large wave motion)
	float wave = fbm(uv, time);
	float eps = 0.1;
	float wave_dx = fbm(uv + vec2(eps, 0.0), time) - wave;
	float wave_dz = fbm(uv + vec2(0.0, eps), time) - wave;
	vec3 wave_normal = normalize(vec3(-wave_dx * 1.5, 1.0, -wave_dz * 1.5));
	
	// Sample normal texture with scrolling animation (fine detail)
	vec2 normal_uv1 = world_pos.xz * normal_texture_scale + time * vec2(0.02, 0.01);
	vec2 normal_uv2 = world_pos.xz * normal_texture_scale * 0.7 - time * vec2(0.015, 0.02);
	vec3 tex_normal1 = texture(water_normal_texture, normal_uv1).rgb * 2.0 - 1.0;
	vec3 tex_normal2 = texture(water_normal_texture, normal_uv2).rgb * 2.0 - 1.0;
	// Blend two scrolling layers for organic look
	vec3 tex_normal = normalize(tex_normal1 + tex_normal2);
	
	// Combine: procedural waves + texture detail
	vec3 combined_normal = normalize(wave_normal + tex_normal * normal_texture_strength);
	
	// Blend combined normal with mesh normal
	vec3 final_normal = normalize(mix(NORMAL, combined_normal, 0.5));
	NORMAL = final_normal;
	
	// Depth calculation
	float depth = texture(depth_texture, SCREEN_UV).x;
	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, depth);
	vec4 view_pos = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	view_pos.xyz /= view_pos.w;
	float linear_depth = -view_pos.z;
	float linear_surface_depth = -VERTEX.z;
	float depth_diff = max(linear_depth - linear_surface_depth, 0.0);
	
	// Beer's Law - depth absorption
	float depth_alpha = clamp(1.0 - exp(-depth_diff * beer_factor), 0.0, 1.0);
	
	// === REFRACTION (subtle) ===
	// Offset screen UV based on wave normal to distort underwater view
	vec2 refract_offset = final_normal.xz * refraction_strength;
	// Only apply refraction in shallow-to-mid depth (avoid deep water blur)
	float refract_mask = smoothstep(0.0, 0.3, depth_diff) * (1.0 - smoothstep(0.5, 1.5, depth_diff));
	refract_offset *= refract_mask;
	vec2 refract_uv = SCREEN_UV + refract_offset;
	// Sample what's behind the water with distortion
	vec3 refracted_color = texture(screen_texture, refract_uv).rgb;
	
	// Three-way color blend: shallow -> mid -> deep
	vec3 color_blend = mix(albedo_shallow, albedo, smoothstep(0.0, 0.3, depth_alpha));
	color_blend = mix(color_blend, albedo_deep, smoothstep(0.4, 1.0, depth_alpha));
	
	// Blend refracted background with water color
	// Only show refraction in shallow/clear water - deep water is just water color
	color_blend = mix(refracted_color, color_blend, 0.4 + depth_alpha * 0.5);
	
	// Subtle shimmer from wave
	float shimmer = wave * 0.08;
	color_blend += shimmer * vec3(0.08, 0.12, 0.15);
	
	// Foam at shallow edges - blue-tinted
	float foam = 0.0;
	if (depth_diff < foam_threshold && depth_diff > 0.0) {
		foam = (1.0 - depth_diff / foam_threshold) * foam_intensity;
		foam *= (0.6 + wave * 0.4);  // Animate foam
	}
	color_blend = mix(color_blend, foam_color, foam);
	
	// Fresnel reflection
	float f = fresnel(4.0, final_normal, VIEW);
	vec3 fresnel_color = vec3(0.45, 0.6, 0.7);
	
	ALBEDO = color_blend + fresnel_color * f * 0.3;
	METALLIC = metallic;
	ROUGHNESS = roughness;
	
	// Alpha: transparent shallow, opaque deep
	ALPHA = clamp(0.35 + depth_alpha * 0.6 + foam * 0.15, 0.0, 0.95);
}
